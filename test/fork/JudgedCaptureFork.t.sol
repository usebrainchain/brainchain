// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAuthCaptureEscrow, JudgedCapture} from "../../src/escrow/JudgedCapture.sol";
import {JudgedCaptureBase} from "../JudgedCapture.t.sol";

interface IEscrowStore {
    function tokenStoreImplementation() external view returns (address);
}

interface ICollector {
    function authCaptureEscrow() external view returns (address);
}

// JudgedCapture against the commerce-payments escrow, its ERC-3009 collector and USDC on a fork of
// Base (chain 8453). The payer signs a real USDC authorization. Skipped without a fork:
//   forge test --match-path test/fork/JudgedCaptureFork.t.sol --fork-url https://mainnet.base.org -vv
contract JudgedCaptureForkTest is JudgedCaptureBase {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint120 constant AMOUNT = 20e6;
    bytes32 constant TASK = keccak256("base order 1");

    JudgedCapture.Terms terms;
    IAuthCaptureEscrow.PaymentInfo p;

    function setUp() public {
        if (block.chainid != 8453) return;
        token = USDC;
        judged = new JudgedCapture(ESCROW, USDC, owner, brain, CAP);
        deal(USDC, payer, 100e6);
        terms = _terms(TASK);
        p = _payment(payer, AMOUNT, terms);
    }

    modifier onFork() {
        if (block.chainid != 8453) return;
        _;
    }

    function test_theLocalTestsRunTheCodeDeployedOnBase() public onFork {
        string memory json = vm.readFile("test/fixtures/commerce-payments-v1.1.0.json");
        assertEq(address(ESCROW).code, vm.parseJsonBytes(json, ".AuthCaptureEscrow.code"));
        assertEq(ERC3009_COLLECTOR.code, vm.parseJsonBytes(json, ".ERC3009PaymentCollector.code"));
        assertEq(TOKEN_STORE.code, vm.parseJsonBytes(json, ".TokenStore.code"));
        assertEq(IEscrowStore(address(ESCROW)).tokenStoreImplementation(), TOKEN_STORE);
        assertEq(ICollector(ERC3009_COLLECTOR).authCaptureEscrow(), address(ESCROW));
    }

    function test_anAcceptedTaskIsHeldThenCapturedToThePayeeWithTheFee() public onFork {
        vm.prank(stranger);
        _authorize(payerKey, p);
        assertEq(IERC20(USDC).balanceOf(payer), 100e6 - AMOUNT);
        assertEq(IERC20(USDC).balanceOf(ESCROW.getTokenStore(address(judged))), AMOUNT);

        JudgedCapture.Decision memory d = _decision(p, TASK, true, 9_100);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.WindowsOpen.selector);
        judged.capture(p, terms, d, sig);

        vm.warp(terms.windowsClose);
        judged.capture(p, terms, d, sig);
        uint256 fee = uint256(AMOUNT) * FEE_BPS / 10_000;
        assertEq(IERC20(USDC).balanceOf(payee), AMOUNT - fee);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee);
        assertEq(_held(p), 0);
        (, uint120 capturable, uint120 refundable) = ESCROW.paymentState(ESCROW.getHash(p));
        assertEq(capturable, 0);
        assertEq(refundable, AMOUNT, "captured, and refundable only by the operator, which has no refund call");
    }

    function test_aRefusedTaskIsVoidedInFullAtOnce() public onFork {
        _authorize(payerKey, p);
        JudgedCapture.Decision memory d = _decision(p, TASK, false, 9_600);
        judged.void(p, terms, d, _sign(brainKey, d));
        assertEq(IERC20(USDC).balanceOf(payer), 100e6);
        assertEq(IERC20(USDC).balanceOf(payee), 0);
        assertEq(_held(p), 0);
    }

    function test_anUndecidedTaskIsReclaimedByThePayerAlone() public onFork {
        _authorize(payerKey, p);
        vm.warp(p.authorizationExpiry);
        // The payer's own transaction; on a Base fork the caller needs gas money.
        vm.deal(payer, 0.001 ether);
        vm.prank(payer);
        ESCROW.reclaim(p);
        assertEq(IERC20(USDC).balanceOf(payer), 100e6);
        assertEq(_held(p), 0);
    }

    function test_theCapHoldsOnBase() public onFork {
        p = _payment(payer, uint120(CAP + 1), terms);
        bytes memory sig = _authorization(payerKey, p);
        vm.expectRevert(JudgedCapture.OverCap.selector);
        judged.authorize(p, CAP + 1, ERC3009_COLLECTOR, sig);
    }
}
