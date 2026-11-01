// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Inscriptions} from "../src/Inscriptions.sol";

contract InscriptionsTest is Test {
    event Inscribed(address indexed by, string kind, bytes data);

    Inscriptions internal inscriptions;

    function setUp() public {
        inscriptions = new Inscriptions();
    }

    function test_emitsTheRecordUnderTheWriter() public {
        bytes memory data = bytes('{"brainchain":1,"kind":"node","image":"v3.11.5-7"}');
        vm.expectEmit(true, true, true, true, address(inscriptions));
        emit Inscribed(address(this), "node", data);
        inscriptions.inscribe("node", data);
    }

    function test_anyoneMayWrite() public {
        address other = makeAddr("other");
        vm.prank(other);
        vm.expectEmit(true, true, true, true, address(inscriptions));
        emit Inscribed(other, "incident", "x");
        inscriptions.inscribe("incident", "x");
    }

    function test_refusesEmptyOrLongKindsAndEmptyData() public {
        vm.expectRevert(bytes("kind"));
        inscriptions.inscribe("", "x");
        vm.expectRevert(bytes("kind"));
        inscriptions.inscribe("abcdefghijklmnopqrstuvwxyz0123456", "x");
        vm.expectRevert(bytes("data"));
        inscriptions.inscribe("node", "");
    }
}
