// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISafeModuleExec} from "../src/safe/CappedTransferModuleV2.sol";
import {IFeeLedger} from "../src/safe/FeeShareModule.sol";
import {FeeShareTransferModule} from "../src/safe/FeeShareTransferModule.sol";
import {Refuser} from "./CappedTransferModuleV2.t.sol";
import {LedgerStandIn} from "./FeeShareModule.t.sol";
import {SafeStandIn} from "./safe/SafeStandIn.sol";

/// Operator and recipient at once: on receiving native token it calls `take` again.
contract TakingTwice {
    FeeShareTransferModule public module;
    uint256 public again;
    bool public swallow;
    bytes public refusal;

    function arm(FeeShareTransferModule module_, uint256 again_, bool swallow_) external {
        module = module_;
        again = again_;
        swallow = swallow_;
    }

    function take(uint256 amount) external {
        module.take(amount);
    }

    receive() external payable {
        uint256 amount = again;
        if (amount == 0) return;
        again = 0;
        if (!swallow) {
            module.take(amount);
            return;
        }
        try module.take(amount) {}
        catch (bytes memory reason) {
            refusal = reason;
        }
    }
}

contract FeeShareTransferModuleTest is Test {
    // What the ledger had paid out before the module, as on Robinhood Chain on 26 November.
    uint256 constant BEFORE = 2.95 ether;
    uint256 constant FUNDED = 10 ether;

    address operator = makeAddr("operator");
    address recipient = makeAddr("buyback wallet");
    address stranger = makeAddr("stranger");
    address weth = makeAddr("weth");
    address income = makeAddr("income");
    SafeStandIn safe;
    LedgerStandIn ledger;
    FeeShareTransferModule module;

    event Taken(uint256 amount, uint256 takenTotal);

    function setUp() public {
        safe = new SafeStandIn();
        ledger = new LedgerStandIn();
        vm.deal(address(safe), FUNDED);
        _paidOut(BEFORE);
        module = _module(recipient, operator, 5, 12);
    }

    function _module(address to, address by, uint256 numerator, uint256 denominator)
        private
        returns (FeeShareTransferModule m)
    {
        m = new FeeShareTransferModule(
            ISafeModuleExec(address(safe)), IFeeLedger(address(ledger)), weth, income, to, by, numerator, denominator
        );
        vm.prank(address(safe));
        safe.enableModule(address(m));
    }

    function _paidOut(uint256 total) private {
        ledger.set(weth, income, total);
    }

    function _take(uint256 amount) private {
        vm.prank(operator);
        module.take(amount);
    }

    function test_theConstructorChecksEachPart() public {
        ISafeModuleExec s = ISafeModuleExec(address(safe));
        IFeeLedger l = IFeeLedger(address(ledger));

        vm.expectRevert(FeeShareTransferModule.ZeroAddress.selector);
        new FeeShareTransferModule(s, l, address(0), income, recipient, operator, 5, 12);
        vm.expectRevert(FeeShareTransferModule.ZeroAddress.selector);
        new FeeShareTransferModule(s, l, weth, address(0), recipient, operator, 5, 12);
        vm.expectRevert(FeeShareTransferModule.ZeroAddress.selector);
        new FeeShareTransferModule(s, l, weth, income, address(0), operator, 5, 12);
        vm.expectRevert(FeeShareTransferModule.ZeroAddress.selector);
        new FeeShareTransferModule(s, l, weth, income, recipient, address(0), 5, 12);
        vm.expectRevert(abi.encodeWithSelector(FeeShareTransferModule.NotAContract.selector, address(0)));
        new FeeShareTransferModule(ISafeModuleExec(address(0)), l, weth, income, recipient, operator, 5, 12);
        vm.expectRevert(abi.encodeWithSelector(FeeShareTransferModule.NotAContract.selector, stranger));
        new FeeShareTransferModule(ISafeModuleExec(stranger), l, weth, income, recipient, operator, 5, 12);
        vm.expectRevert(abi.encodeWithSelector(FeeShareTransferModule.NotAContract.selector, stranger));
        new FeeShareTransferModule(s, IFeeLedger(stranger), weth, income, recipient, operator, 5, 12);
        vm.expectRevert(FeeShareTransferModule.BadShare.selector);
        new FeeShareTransferModule(s, l, weth, income, recipient, operator, 0, 12);
        vm.expectRevert(FeeShareTransferModule.BadShare.selector);
        new FeeShareTransferModule(s, l, weth, income, recipient, operator, 13, 12);
        vm.expectRevert(FeeShareTransferModule.BadShare.selector);
        new FeeShareTransferModule(s, l, weth, income, recipient, operator, 0, 0);
        vm.expectRevert(FeeShareTransferModule.SafeIsOperator.selector);
        new FeeShareTransferModule(s, l, weth, income, recipient, address(safe), 5, 12);
        vm.expectRevert(FeeShareTransferModule.SafeIsRecipient.selector);
        new FeeShareTransferModule(s, l, weth, income, address(safe), operator, 5, 12);
    }

    function test_everyPartIsFixedAtDeployment() public view {
        assertEq(address(module.SAFE()), address(safe));
        assertEq(address(module.LEDGER()), address(ledger));
        assertEq(module.FEE_TOKEN(), weth);
        assertEq(module.INCOME(), income);
        assertEq(module.RECIPIENT(), recipient);
        assertEq(module.OPERATOR(), operator);
        assertEq(module.SHARE_NUMERATOR(), 5);
        assertEq(module.SHARE_DENOMINATOR(), 12);
        assertEq(module.BASELINE(), BEFORE);
        assertEq(module.taken(), 0);
    }

    function test_onlyPayoutsAfterDeploymentCount() public {
        assertEq(module.earned(), 0, "what was paid out before earns nothing");
        assertEq(module.due(), 0);

        _paidOut(BEFORE + 1.2 ether);
        assertEq(module.earned(), 0.5 ether);
        assertEq(module.due(), 0.5 ether);

        ledger.set(weth, stranger, 100 ether);
        ledger.set(stranger, income, 100 ether);
        assertEq(module.earned(), 0.5 ether, "only the income account's payouts in the fee token");
    }

    function test_aModuleDeployedOnAnEmptyLedgerCountsEverything() public {
        _paidOut(0);
        FeeShareTransferModule fresh = _module(recipient, operator, 5, 12);
        assertEq(fresh.BASELINE(), 0);
        _paidOut(1.2 ether);
        assertEq(fresh.earned(), 0.5 ether);
    }

    function test_takesUpToWhatIsDueAndOnlyToTheRecipient() public {
        _paidOut(BEFORE + 1.2 ether);

        vm.expectCall(
            address(safe), abi.encodeCall(ISafeModuleExec.execTransactionFromModule, (recipient, 0.2 ether, "", 0)), 1
        );
        vm.expectEmit(address(module));
        emit Taken(0.2 ether, 0.2 ether);
        _take(0.2 ether);
        assertEq(recipient.balance, 0.2 ether);
        assertEq(address(safe).balance, FUNDED - 0.2 ether);
        assertEq(module.taken(), 0.2 ether);
        assertEq(module.due(), 0.3 ether);

        vm.expectEmit(address(module));
        emit Taken(0.3 ether, 0.5 ether);
        _take(0.3 ether);
        assertEq(recipient.balance, 0.5 ether, "exactly what was due");
        assertEq(address(safe).balance, FUNDED - 0.5 ether);
        assertEq(module.due(), 0);
        assertEq(operator.balance, 0);
        assertEq(stranger.balance, 0);
        assertEq(address(module).balance, 0);
    }

    function test_refusesMoreThanIsDue() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(FeeShareTransferModule.OverDue.selector, 1, 0));
        module.take(1);

        _paidOut(BEFORE + 1.2 ether);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(FeeShareTransferModule.OverDue.selector, 0.5 ether + 1, 0.5 ether));
        module.take(0.5 ether + 1);

        _take(0.4 ether);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(FeeShareTransferModule.OverDue.selector, 0.1 ether + 1, 0.1 ether));
        module.take(0.1 ether + 1);
        assertEq(recipient.balance, 0.4 ether);
    }

    function test_refusesZero() public {
        _paidOut(BEFORE + 1.2 ether);
        vm.prank(operator);
        vm.expectRevert(FeeShareTransferModule.ZeroAmount.selector);
        module.take(0);
        assertEq(module.taken(), 0);
    }

    function test_onlyTheOperatorTakes() public {
        _paidOut(BEFORE + 1.2 ether);
        address[4] memory others = [stranger, address(safe), recipient, income];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(FeeShareTransferModule.NotOperator.selector);
            module.take(0.1 ether);
        }
        assertEq(recipient.balance, 0);
        assertEq(module.taken(), 0);
    }

    function test_theOperatorCannotUseTheSafeAsAModule() public {
        vm.prank(operator);
        vm.expectRevert("GS104");
        safe.execTransactionFromModule(operator, 1 ether, "", 0);
    }

    function test_dueGrowsAsTheLedgerPaysOutMore() public {
        _paidOut(BEFORE + 0.12 ether);
        assertEq(module.due(), 0.05 ether);
        _take(0.05 ether);
        assertEq(module.due(), 0);

        _paidOut(BEFORE + 0.36 ether);
        assertEq(module.earned(), 0.15 ether);
        assertEq(module.due(), 0.1 ether, "only what was earned since");

        _paidOut(BEFORE + 2.4 ether);
        assertEq(module.due(), 0.95 ether);
        _take(0.95 ether);
        assertEq(recipient.balance, 1 ether);
        assertEq(module.taken(), 1 ether);
    }

    /// The buyback job holds one key, so it may be both: the module only ever pays the recipient, and the key gains
    /// nothing over being the operator alone. Anyone else is still refused.
    function test_theOperatorMayBeTheRecipient() public {
        address job = makeAddr("buyback job");
        FeeShareTransferModule m = _module(job, job, 5, 12);
        assertEq(m.OPERATOR(), m.RECIPIENT());
        _paidOut(BEFORE + 1.2 ether);

        vm.prank(stranger);
        vm.expectRevert(FeeShareTransferModule.NotOperator.selector);
        m.take(0.5 ether);

        vm.prank(job);
        m.take(0.5 ether);
        assertEq(job.balance, 0.5 ether);
        assertEq(address(safe).balance, FUNDED - 0.5 ether);

        vm.prank(job);
        vm.expectRevert(abi.encodeWithSelector(FeeShareTransferModule.OverDue.selector, 1, 0));
        m.take(1);
    }

    function test_aSafeThatRefusesTheTransferMovesNothing() public {
        _paidOut(BEFORE + 1.2 ether);
        vm.mockCall(
            address(safe),
            abi.encodeCall(ISafeModuleExec.execTransactionFromModule, (recipient, 0.5 ether, "", 0)),
            abi.encode(false)
        );
        vm.prank(operator);
        vm.expectRevert(FeeShareTransferModule.TransferFailed.selector);
        module.take(0.5 ether);
        assertEq(module.taken(), 0);
        assertEq(module.due(), 0.5 ether, "and it is still due");
        assertEq(recipient.balance, 0);
    }

    function test_aSafeWithoutTheMoneyMovesNothing() public {
        vm.deal(address(safe), 0.1 ether);
        _paidOut(BEFORE + 1.2 ether);
        vm.prank(operator);
        vm.expectRevert(FeeShareTransferModule.TransferFailed.selector);
        module.take(0.5 ether);
        assertEq(module.taken(), 0);
        assertEq(address(safe).balance, 0.1 ether);

        _take(0.1 ether);
        assertEq(recipient.balance, 0.1 ether);
    }

    function test_aRecipientThatRefusesNativeTokenGetsNothing() public {
        address refuser = address(new Refuser());
        FeeShareTransferModule m = _module(refuser, operator, 5, 12);
        _paidOut(BEFORE + 1.2 ether);
        vm.prank(operator);
        vm.expectRevert(FeeShareTransferModule.TransferFailed.selector);
        m.take(0.5 ether);
        assertEq(m.taken(), 0);
        assertEq(address(safe).balance, FUNDED);
    }

    function test_aDisabledModuleDoesNothing() public {
        _paidOut(BEFORE + 1.2 ether);
        vm.prank(address(safe));
        safe.disableModule(address(module));
        vm.prank(operator);
        vm.expectRevert(bytes("GS104"));
        module.take(0.5 ether);
        assertEq(address(safe).balance, FUNDED);
        assertEq(module.taken(), 0);
    }

    /// The Safe ends the module whenever it likes, with any amount due, and enables another with other numbers.
    function test_theSafeEndsItAtAnyTimeAndEnablesAReplacement() public {
        _paidOut(BEFORE + 1.2 ether);
        _take(0.2 ether);

        vm.prank(address(safe));
        safe.disableModule(address(module));
        vm.prank(operator);
        vm.expectRevert(bytes("GS104"));
        module.take(0.3 ether);
        _paidOut(BEFORE + 12 ether);
        vm.prank(operator);
        vm.expectRevert(bytes("GS104"));
        module.take(1 ether);
        assertEq(address(safe).balance, FUNDED - 0.2 ether, "nothing moved after it was disabled");
        assertEq(recipient.balance, 0.2 ether);

        address next = makeAddr("next buyback wallet");
        FeeShareTransferModule replacement = _module(next, next, 1, 4);
        assertEq(replacement.BASELINE(), BEFORE + 12 ether);
        assertEq(replacement.due(), 0, "the replacement counts from its own deployment");
        _paidOut(BEFORE + 16 ether);
        vm.prank(next);
        replacement.take(1 ether);
        assertEq(next.balance, 1 ether);
        assertEq(address(safe).balance, FUNDED - 1.2 ether);

        vm.prank(operator);
        vm.expectRevert(bytes("GS104"));
        module.take(1 ether);
    }

    function test_itHoldsNoFundsAndTakesNone() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(module).call{value: 1 ether}("");
        assertFalse(ok, "no receive");
        (ok,) = address(module).call{value: 1 ether}(abi.encodeCall(FeeShareTransferModule.take, (1)));
        assertFalse(ok, "take is not payable");

        _paidOut(BEFORE + 1.2 ether);
        _take(0.5 ether);
        assertEq(address(module).balance, 0);
    }

    /// No call outside the module's thirteen functions does anything: there is no fallback, owner, setter or upgrade.
    function testFuzz_nothingElseCanBeCalled(bytes4 selector, bytes calldata rest) public {
        bytes4[13] memory known = [
            module.SAFE.selector,
            module.LEDGER.selector,
            module.FEE_TOKEN.selector,
            module.INCOME.selector,
            module.RECIPIENT.selector,
            module.OPERATOR.selector,
            module.SHARE_NUMERATOR.selector,
            module.SHARE_DENOMINATOR.selector,
            module.BASELINE.selector,
            module.taken.selector,
            module.earned.selector,
            module.due.selector,
            module.take.selector
        ];
        for (uint256 i; i < known.length; i++) {
            vm.assume(selector != known[i]);
        }
        _paidOut(BEFORE + 1.2 ether);
        address[3] memory callers = [operator, address(safe), stranger];
        for (uint256 i; i < callers.length; i++) {
            vm.prank(callers[i]);
            (bool ok,) = address(module).call(abi.encodePacked(selector, rest));
            assertFalse(ok);
        }
        assertEq(address(safe).balance, FUNDED);
    }

    /// The deployed code has no SELFDESTRUCT, DELEGATECALL or CALLCODE, so it can neither vanish nor run other code
    /// as itself. Push data and the compiler's metadata are skipped, as they are never executed.
    function test_theCodeCannotSelfDestructOrDelegate() public view {
        bytes memory code = address(module).code;
        uint256 metadata = uint16(bytes2(bytes.concat(code[code.length - 2], code[code.length - 1])));
        uint256 end = code.length - metadata - 2;
        uint256 ops;
        for (uint256 i; i < end; i++) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            ops++;
        }
        assertGt(ops, 100);
    }

    function test_aLedgerThatReadsLowerLeavesNothingDue() public {
        _paidOut(BEFORE + 1.2 ether);
        _take(0.5 ether);

        _paidOut(BEFORE + 0.6 ether);
        assertEq(module.earned(), 0.25 ether);
        assertEq(module.due(), 0, "below what was taken");

        _paidOut(BEFORE - 1 ether);
        assertEq(module.earned(), 0, "below the baseline");
        assertEq(module.due(), 0);

        _paidOut(BEFORE + 1.44 ether);
        assertEq(module.due(), 0.1 ether, "recovered, the same share is never due twice");
    }

    function test_theRecipientCannotTakeTwiceByReentering() public {
        TakingTwice r = new TakingTwice();
        FeeShareTransferModule m = _module(address(r), address(r), 5, 12);
        _paidOut(BEFORE + 1.2 ether);

        // Passed on, the refusal fails the Safe's call and nothing moves.
        r.arm(m, 0.5 ether, false);
        vm.expectRevert(FeeShareTransferModule.TransferFailed.selector);
        r.take(0.5 ether);
        assertEq(address(r).balance, 0);
        assertEq(m.taken(), 0);

        // Caught, only the outer take goes through: taken was raised before the Safe paid.
        r.arm(m, 0.5 ether, true);
        r.take(0.5 ether);
        assertEq(r.refusal(), abi.encodeWithSelector(FeeShareTransferModule.OverDue.selector, 0.5 ether, 0));
        assertEq(address(r).balance, 0.5 ether);
        assertEq(m.taken(), 0.5 ether);
        assertEq(address(safe).balance, FUNDED - 0.5 ether);
    }

    function test_reenteringForTheRestTakesNoMoreThanIsDue() public {
        TakingTwice r = new TakingTwice();
        FeeShareTransferModule m = _module(address(r), address(r), 5, 12);
        _paidOut(BEFORE + 1.2 ether);

        r.arm(m, 0.4 ether, true);
        r.take(0.3 ether);
        assertEq(r.refusal(), abi.encodeWithSelector(FeeShareTransferModule.OverDue.selector, 0.4 ether, 0.2 ether));
        assertEq(address(r).balance, 0.3 ether);

        r.arm(m, 0.1 ether, true);
        r.take(0.1 ether);
        assertEq(address(r).balance, 0.5 ether, "the inner take spent the rest of what was due");
        assertEq(m.taken(), 0.5 ether);
        assertEq(m.due(), 0);
    }

    /// However the payouts and takes fall, at any share, the takes never add up past the exact share of what was paid
    /// out since deployment, and the module reports due as exactly the floor of that share less what was taken.
    function testFuzz_roundingNeverTakesMoreThanEarned(
        uint64[8] memory payouts,
        uint256[8] memory cuts,
        uint256 numerator,
        uint256 denominator
    ) public {
        uint256 d = bound(denominator, 1, 1_000_000);
        uint256 n = bound(numerator, 1, d);
        FeeShareTransferModule m = _module(recipient, operator, n, d);
        vm.deal(address(safe), type(uint128).max);

        uint256 paid = BEFORE;
        uint256 sum;
        for (uint256 i; i < payouts.length; i++) {
            paid += payouts[i];
            _paidOut(paid);
            uint256 share = (paid - BEFORE) * n / d;
            assertEq(m.earned(), share);
            assertEq(m.due(), share - sum);

            uint256 amount = bound(cuts[i], 0, share - sum);
            if (amount > 0) {
                vm.prank(operator);
                m.take(amount);
                sum += amount;
            }
            vm.prank(operator);
            vm.expectRevert(
                abi.encodeWithSelector(FeeShareTransferModule.OverDue.selector, share - sum + 1, share - sum)
            );
            m.take(share - sum + 1);

            assertLe(sum, m.earned());
            assertLe(sum * d, (paid - BEFORE) * n, "never past the exact share");
            assertEq(recipient.balance, sum);
            assertEq(m.taken(), sum);
        }
    }

    /// Taking all that is due after every payout leaves no dust behind: the takes add up to the share of the total.
    function testFuzz_takingAllThatIsDueSumsToTheShareOfTheTotal(uint64[8] memory payouts, uint256 denominator) public {
        uint256 d = bound(denominator, 2, 97);
        FeeShareTransferModule m = _module(recipient, operator, 1, d);
        vm.deal(address(safe), type(uint128).max);

        uint256 paid = BEFORE;
        for (uint256 i; i < payouts.length; i++) {
            paid += payouts[i];
            _paidOut(paid);
            uint256 amount = m.due();
            if (amount == 0) continue;
            vm.prank(operator);
            m.take(amount);
        }
        assertEq(recipient.balance, (paid - BEFORE) / d);
        assertEq(m.due(), 0);
    }
}

contract FeeShareTransferHandler is Test {
    SafeStandIn internal immutable safe;
    LedgerStandIn internal immutable ledger;
    FeeShareTransferModule internal immutable module;
    address internal immutable weth;
    address internal immutable income;
    address internal immutable operator;

    uint256 public highestPaidOut;
    uint256 public sent;
    uint256 public refusedWithinDue;
    uint256 public movedByOthers;

    constructor(SafeStandIn safe_, LedgerStandIn ledger_, FeeShareTransferModule module_) {
        safe = safe_;
        ledger = ledger_;
        module = module_;
        weth = module_.FEE_TOKEN();
        income = module_.INCOME();
        operator = module_.OPERATOR();
        highestPaidOut = module_.BASELINE();
    }

    function payOut(uint256 amount) external {
        uint256 total = highestPaidOut + bound(amount, 0, 2 ether);
        highestPaidOut = total;
        ledger.set(weth, income, total);
    }

    function readLower(uint256 amount) external {
        ledger.set(weth, income, bound(amount, 0, highestPaidOut));
    }

    function recover() external {
        ledger.set(weth, income, highestPaidOut);
    }

    function take(uint256 amount) external {
        uint256 due = module.due();
        amount = bound(amount, 1, due * 3 / 2 + 2);
        uint256 before = address(safe).balance;
        vm.prank(operator);
        try module.take(amount) {} catch {}
        uint256 fell = before - address(safe).balance;
        if (fell == 0 && amount <= due && amount <= before) refusedWithinDue++;
        sent += fell;
    }

    function takeAsAnother(uint256 amount, uint256 who) external {
        address[4] memory others = [address(safe), module.RECIPIENT(), income, makeAddr("stranger")];
        uint256 before = address(safe).balance;
        vm.prank(others[who % 4]);
        try module.take(bound(amount, 1, 1 ether)) {} catch {}
        if (address(safe).balance != before) movedByOthers++;
    }

    function callSafeDirectly(uint256 amount) external {
        uint256 before = address(safe).balance;
        vm.prank(operator);
        try safe.execTransactionFromModule(operator, bound(amount, 1, 1 ether), "", 0) {} catch {}
        if (address(safe).balance != before) movedByOthers++;
    }
}

contract FeeShareTransferModuleInvariants is Test {
    uint256 constant FUNDED = 1_000 ether;
    uint256 constant BEFORE = 2.95 ether;

    SafeStandIn safe;
    LedgerStandIn ledger;
    FeeShareTransferModule module;
    FeeShareTransferHandler handler;
    address recipient = makeAddr("buyback wallet");

    function setUp() public {
        safe = new SafeStandIn();
        ledger = new LedgerStandIn();
        vm.deal(address(safe), FUNDED);
        ledger.set(makeAddr("weth"), makeAddr("income"), BEFORE);
        module = new FeeShareTransferModule(
            ISafeModuleExec(address(safe)),
            IFeeLedger(address(ledger)),
            makeAddr("weth"),
            makeAddr("income"),
            recipient,
            makeAddr("operator"),
            5,
            12
        );
        vm.prank(address(safe));
        safe.enableModule(address(module));
        handler = new FeeShareTransferHandler(safe, ledger, module);
        targetContract(address(handler));
    }

    function invariant_neverSentMoreThanTheHighestShareEarned() public view {
        assertLe(handler.sent(), (handler.highestPaidOut() - BEFORE) * 5 / 12);
    }

    function invariant_takenIsWhatTheRecipientGot() public view {
        assertEq(module.taken(), handler.sent());
        assertEq(recipient.balance, handler.sent());
    }

    function invariant_fundsGoOnlyToTheRecipient() public view {
        assertEq(address(safe).balance + recipient.balance, FUNDED);
    }

    function invariant_onlyTheOperatorMovesFunds() public view {
        assertEq(handler.movedByOthers(), 0);
    }

    function invariant_takesWithinDueGoThrough() public view {
        assertEq(handler.refusedWithinDue(), 0);
    }
}
