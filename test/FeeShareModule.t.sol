// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISafeModuleCall} from "../src/safe/CappedTransferModule.sol";
import {FeeShareModule, IFeeLedger, IPairLock} from "../src/safe/FeeShareModule.sol";
import {SafeStandIn} from "./safe/SafeStandIn.sol";

contract LedgerStandIn {
    mapping(address token => mapping(address account => uint256)) public claimed;

    function set(address token, address account, uint256 amount) external {
        claimed[token][account] = amount;
    }
}

/// Takes native token and pairs on its owner's call, as the lock does. `refuse` makes `pair` revert the way the
/// lock does for a price outside the bounds.
contract LockStandIn {
    error PriceOutOfBounds(uint160 price);

    address public owner;
    bool public refuse;
    uint256 public pairs;
    uint256 public pairedTotal;
    uint160 public lastMin;
    uint160 public lastMax;

    constructor(address owner_) {
        owner = owner_;
    }

    receive() external payable {}

    function setRefuse(bool refuse_) external {
        refuse = refuse_;
    }

    function pair(uint160 minPrice, uint160 maxPrice) external returns (uint256 tokenId) {
        require(msg.sender == owner, "not the owner");
        if (refuse) revert PriceOutOfBounds(minPrice);
        pairedTotal = address(this).balance;
        lastMin = minPrice;
        lastMax = maxPrice;
        return ++pairs;
    }
}

contract FeeShareModuleTest is Test {
    uint256 constant BEFORE = 0.0726 ether;

    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");
    address weth = makeAddr("weth");
    address income = makeAddr("income");
    SafeStandIn safe;
    LedgerStandIn ledger;
    LockStandIn lock;
    FeeShareModule module;

    event Passed(uint256 amount, uint256 passedTotal, uint256 tokenId);

    function setUp() public {
        safe = new SafeStandIn();
        ledger = new LedgerStandIn();
        lock = new LockStandIn(address(safe));
        vm.deal(address(safe), 10 ether);
        module = _module(1, 6, BEFORE);
        vm.prank(address(safe));
        safe.enableModule(address(module));
    }

    function _module(uint256 numerator, uint256 denominator, uint256 passedBefore) private returns (FeeShareModule) {
        return new FeeShareModule(
            ISafeModuleCall(address(safe)),
            IFeeLedger(address(ledger)),
            weth,
            income,
            IPairLock(address(lock)),
            operator,
            numerator,
            denominator,
            passedBefore
        );
    }

    function _paidOut(uint256 amount) private {
        ledger.set(weth, income, amount);
    }

    function test_theConstructorChecksEachPart() public {
        ISafeModuleCall s = ISafeModuleCall(address(safe));
        IFeeLedger l = IFeeLedger(address(ledger));
        IPairLock k = IPairLock(address(lock));

        vm.expectRevert(FeeShareModule.ZeroAddress.selector);
        new FeeShareModule(s, l, address(0), income, k, operator, 1, 6, 0);
        vm.expectRevert(FeeShareModule.ZeroAddress.selector);
        new FeeShareModule(s, l, weth, address(0), k, operator, 1, 6, 0);
        vm.expectRevert(FeeShareModule.ZeroAddress.selector);
        new FeeShareModule(s, l, weth, income, k, address(0), 1, 6, 0);
        vm.expectRevert(abi.encodeWithSelector(FeeShareModule.NotAContract.selector, stranger));
        new FeeShareModule(ISafeModuleCall(stranger), l, weth, income, k, operator, 1, 6, 0);
        vm.expectRevert(abi.encodeWithSelector(FeeShareModule.NotAContract.selector, stranger));
        new FeeShareModule(s, IFeeLedger(stranger), weth, income, k, operator, 1, 6, 0);
        vm.expectRevert(abi.encodeWithSelector(FeeShareModule.NotAContract.selector, stranger));
        new FeeShareModule(s, l, weth, income, IPairLock(stranger), operator, 1, 6, 0);
        vm.expectRevert(FeeShareModule.BadShare.selector);
        new FeeShareModule(s, l, weth, income, k, operator, 0, 6, 0);
        vm.expectRevert(FeeShareModule.BadShare.selector);
        new FeeShareModule(s, l, weth, income, k, operator, 7, 6, 0);
        vm.expectRevert(FeeShareModule.SafeIsOperator.selector);
        new FeeShareModule(s, l, weth, income, k, address(safe), 1, 6, 0);

        LockStandIn foreign = new LockStandIn(stranger);
        vm.expectRevert(abi.encodeWithSelector(FeeShareModule.NotLockOwner.selector, stranger));
        new FeeShareModule(s, l, weth, income, IPairLock(address(foreign)), operator, 1, 6, 0);
    }

    function test_theShareIsAFractionOfWhatWasPaidOutLessWhatWasPassed() public {
        assertEq(module.passed(), BEFORE);
        assertEq(module.due(), 0, "nothing paid out, nothing due");

        _paidOut(0.3 ether);
        assertEq(module.earned(), 0.05 ether);
        assertEq(module.due(), 0, "what was passed by hand already covers it");

        _paidOut(0.6 ether);
        assertEq(module.earned(), 0.1 ether);
        assertEq(module.due(), 0.1 ether - BEFORE);
    }

    function test_onlyTheOperatorPasses() public {
        _paidOut(0.6 ether);
        vm.prank(stranger);
        vm.expectRevert(FeeShareModule.NotOperator.selector);
        module.passAndPair(1, 2);
        vm.prank(address(safe));
        vm.expectRevert(FeeShareModule.NotOperator.selector);
        module.passAndPair(1, 2);
    }

    function test_nothingDueMovesNothing() public {
        _paidOut(0.3 ether);
        vm.prank(operator);
        vm.expectRevert(FeeShareModule.NothingDue.selector);
        module.passAndPair(1, 2);
        assertEq(address(lock).balance, 0);
    }

    function test_passesWhatIsDueAndPairsIt() public {
        _paidOut(0.6 ether);
        uint256 due = 0.1 ether - BEFORE;

        vm.expectEmit(address(module));
        emit Passed(due, 0.1 ether, 1);
        vm.prank(operator);
        (uint256 amount, uint256 tokenId) = module.passAndPair(111, 222);

        assertEq(amount, due);
        assertEq(tokenId, 1);
        assertEq(address(lock).balance, due);
        assertEq(address(safe).balance, 10 ether - due);
        assertEq(lock.lastMin(), 111, "the operator's bounds reach the lock");
        assertEq(lock.lastMax(), 222);
        assertEq(module.passed(), 0.1 ether);
        assertEq(module.due(), 0);

        vm.prank(operator);
        vm.expectRevert(FeeShareModule.NothingDue.selector);
        module.passAndPair(111, 222);

        _paidOut(0.9 ether);
        vm.prank(operator);
        (amount, tokenId) = module.passAndPair(111, 222);
        assertEq(amount, 0.05 ether, "only what was earned since");
        assertEq(tokenId, 2);
        assertEq(address(lock).balance, due + 0.05 ether);
    }

    function test_aLockThatRefusesToPairGetsNothing() public {
        _paidOut(0.6 ether);
        lock.setRefuse(true);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                FeeShareModule.PairFailed.selector,
                abi.encodeWithSelector(LockStandIn.PriceOutOfBounds.selector, uint160(111))
            )
        );
        module.passAndPair(111, 222);

        assertEq(address(lock).balance, 0, "the share stays in the Safe");
        assertEq(address(safe).balance, 10 ether);
        assertEq(module.passed(), BEFORE);
        assertEq(module.due(), 0.1 ether - BEFORE, "and is still due");
    }

    function test_aSafeWithoutTheMoneyPassesNothing() public {
        vm.deal(address(safe), 0.01 ether);
        _paidOut(0.6 ether);
        vm.prank(operator);
        vm.expectRevert(FeeShareModule.TransferFailed.selector);
        module.passAndPair(1, 2);
        assertEq(module.passed(), BEFORE);
    }

    function test_aDisabledModuleDoesNothing() public {
        _paidOut(0.6 ether);
        vm.prank(address(safe));
        safe.disableModule(address(module));
        vm.prank(operator);
        vm.expectRevert(bytes("GS104"));
        module.passAndPair(1, 2);
        assertEq(address(safe).balance, 10 ether);
    }

    function test_aLedgerThatReadsLowerLeavesNothingDue() public {
        _paidOut(0.6 ether);
        vm.prank(operator);
        module.passAndPair(1, 2);
        _paidOut(0.1 ether);
        assertEq(module.due(), 0);
    }

    /// Whatever the ledger reports and however often the operator calls, the lock holds exactly the highest share the
    /// module was called at, less what was passed before the module: a ledger that reads lower and recovers never
    /// has the same share passed twice.
    function testFuzz_neverMoreThanTheShare(uint64[8] memory steps, uint8 numerator, uint256 passedBefore) public {
        uint256 n = bound(numerator, 1, 6);
        passedBefore = bound(passedBefore, 0, 1 ether);
        FeeShareModule m = _module(n, 6, passedBefore);
        vm.prank(address(safe));
        safe.enableModule(address(m));
        vm.deal(address(safe), 1_000_000 ether);

        uint256 paidOut;
        uint256 expected = passedBefore;
        for (uint256 i; i < steps.length; i++) {
            paidOut = steps[i] % 2 == 0 ? paidOut + steps[i] : steps[i];
            _paidOut(paidOut);
            uint256 share = paidOut * n / 6;
            vm.prank(operator);
            if (share > expected) {
                (uint256 amount,) = m.passAndPair(1, 2);
                assertEq(amount, share - expected);
                expected = share;
            } else {
                vm.expectRevert(FeeShareModule.NothingDue.selector);
                m.passAndPair(1, 2);
            }
            assertEq(m.passed(), expected);
            assertEq(address(lock).balance, expected - passedBefore);
        }
    }
}
