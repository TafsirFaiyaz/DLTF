// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DLTFRegistry.sol";

/**
 * @dev Mirrors chain/evm_parity_test.py. Every rejection reason has a test
 *      whose name maps 1:1 to the Python test.
 *
 *      Run with:  forge test -vvv
 *
 *      This file is provided for teams that prefer Foundry over the Python
 *      harness. The Python harness (PYTHONPATH=. python3 -m chain.evm_parity_test)
 *      is the authoritative spec compliance test: it drives the same
 *      contract from the SAME code path Python uses in production. This
 *      Foundry file duplicates the coverage as an independent check.
 */
contract DLTFRegistryTest is Test {
    DLTFRegistry public reg;
    address public server = address(0xA11CE);
    address public other  = address(0xB0B);

    bytes32 constant CHAIN_ID = bytes32(uint256(1));

    function _ek(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }

    function _key(string memory did) internal pure returns (bytes32) {
        return keccak256(bytes(did));
    }

    function setUp() public {
        vm.prank(server);
        reg = new DLTFRegistry(server, CHAIN_ID);
    }

    // -- deploy state -------------------------------------------------------

    function test_deploy_state() public {
        assertEq(reg.server(), server);
        assertFalse(reg.lastRoundSet());
    }

    // -- happy path ---------------------------------------------------------

    function test_enroll_then_classify_neutral() public {
        vm.startPrank(server);
        reg.register("alpha", 1, _ek("ek_alpha"));                  // HARDWARE
        reg.classify(0, "alpha", 1, 0, "");                         // NEUTRAL
        vm.stopPrank();

        DLTFRegistry.DeviceState memory d = reg.getDeviceState("alpha");
        assertEq(d.s, 400_000);           // s = decay(0) + THETA
        assertEq(d.cleanRun, 1);
        assertEq(d.status, 0);            // ACTIVE
    }

    // -- rejection rules ---------------------------------------------------

    function test_reject_unauthorized_writer() public {
        vm.expectRevert(DLTFRegistry.UnauthorizedWriter.selector);
        vm.prank(other);
        reg.register("x", 1, _ek("ek_x"));
    }

    function test_reject_tier_mutation() public {
        vm.startPrank(server);
        reg.register("beta", 2, _ek("ek_beta"));                    // TPM_RESIDENT
        vm.expectRevert(abi.encodeWithSelector(
            DLTFRegistry.TierMutation.selector, _key("beta"), uint8(2), uint8(1)));
        reg.register("beta", 1, _ek("ek_beta"));
        vm.stopPrank();
    }

    function test_reject_ek_already_registered() public {
        vm.startPrank(server);
        reg.register("d1", 1, _ek("ek_shared"));
        vm.expectRevert(abi.encodeWithSelector(
            DLTFRegistry.EkAlreadyRegistered.selector, _ek("ek_shared")));
        reg.register("d2", 1, _ek("ek_shared"));
        vm.stopPrank();
    }

    function test_reject_ban_to_active() public {
        vm.startPrank(server);
        reg.register("z", 3, _ek("ek_z"));                          // SOFTWARE
        reg.classify(0, "z", 4, 3, "");                             // CRITICAL
        vm.expectRevert(abi.encodeWithSelector(
            DLTFRegistry.BanToActive.selector, _key("z")));
        reg.register("z", 3, _ek("ek_z_fresh"));
        vm.stopPrank();
    }

    function test_reject_duplicate_round() public {
        vm.startPrank(server);
        reg.register("g", 1, _ek("ek_g"));
        reg.classify(5, "g", 1, 0, "");
        reg.roundSummary(5, keccak256("g"), true, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(
            DLTFRegistry.DuplicateRound.selector, uint256(5)));
        reg.roundSummary(5, keccak256("g"), true, bytes32(0));
        vm.stopPrank();
    }

    function test_reject_stale_round() public {
        vm.startPrank(server);
        reg.register("g", 1, _ek("ek_g"));
        reg.classify(5, "g", 1, 0, "");
        reg.roundSummary(5, keccak256("g"), true, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(
            DLTFRegistry.StaleRound.selector, uint256(3), uint256(5)));
        reg.classify(3, "g", 1, 0, "");
        vm.stopPrank();
    }

    function test_reject_device_banned() public {
        vm.startPrank(server);
        reg.register("b", 3, _ek("ek_b"));
        reg.classify(0, "b", 4, 3, "");                             // CRITICAL
        vm.expectRevert(abi.encodeWithSelector(
            DLTFRegistry.DeviceBanned.selector, _key("b")));
        reg.classify(1, "b", 1, 0, "");
        vm.stopPrank();
    }

    function test_reject_device_unknown() public {
        vm.startPrank(server);
        vm.expectRevert(abi.encodeWithSelector(
            DLTFRegistry.DeviceUnknown.selector, _key("ghost")));
        reg.classify(0, "ghost", 1, 0, "");
        vm.stopPrank();
    }

    // -- whitewash ---------------------------------------------------------

    function test_whitewash_rejected_after_ban() public {
        vm.startPrank(server);
        reg.register("victim", 1, _ek("ek_v"));
        reg.classify(0, "victim", 4, 3, "");                        // CRITICAL

        vm.expectEmit(false, false, false, true);
        emit DLTFRegistry.WhitewashRejected("victim_v2", _ek("ek_v"));
        reg.register("victim_v2", 1, _ek("ek_v"));
        vm.stopPrank();

        assertEq(reg.getDevice("victim_v2"), 0);
        assertTrue(reg.isBannedEk(_ek("ek_v")));
    }

    // -- probation lifecycle -----------------------------------------------

    function test_probation_reinstate_then_exhaust() public {
        vm.startPrank(server);
        reg.register("hw", 1, _ek("ek_hw"));                        // HARDWARE

        for (uint256 r = 0; r < 3; r++) {
            reg.classify(r, "hw", 3, 2, "");                        // MAJOR
        }
        assertEq(reg.getDeviceState("hw").status, 1);               // PROBATION

        reg.enterProbation(3, "hw");
        reg.probationDecision(10, "hw", 0);                         // REINSTATED
        assertEq(reg.getDeviceState("hw").status, 0);               // ACTIVE
        assertTrue(reg.isRehabUsed("hw"));

        for (uint256 r = 11; r < 14; r++) {
            reg.classify(r, "hw", 3, 2, "");
        }
        assertEq(reg.getDeviceState("hw").status, 1);

        vm.expectRevert(abi.encodeWithSelector(
            DLTFRegistry.NotOnProbation.selector, _key("hw")));
        reg.enterProbation(14, "hw");

        reg.exhaustProbation(14, "hw");
        assertEq(reg.getDeviceState("hw").status, 2);               // BANNED
        vm.stopPrank();
    }

    // -- packed slot fits in 208 bits --------------------------------------

    function test_packed_word_under_208_bits() public {
        vm.startPrank(server);
        reg.register("d", 1, _ek("ek_d"));
        for (uint256 r = 0; r < 5; r++) {
            reg.classify(r, "d", 1, 0, "");
        }
        vm.stopPrank();
        uint256 word = reg.getDevice("d");
        // upper 48 bits must be zero
        assertEq(word >> 208, 0);
    }

    // -- gas measurement (informational; not a pass/fail assertion) -------

    function test_gas_classify_warm() public {
        vm.startPrank(server);
        reg.register("g", 1, _ek("ek_g"));
        reg.classify(0, "g", 1, 0, "");                             // warm slot
        uint256 g0 = gasleft();
        reg.classify(1, "g", 1, 0, "");
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        emit log_named_uint("gas: warm classify NEUTRAL", used);
    }
}
