// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DogHoodToken} from "../src/DogHoodToken.sol";

/// @notice Deploys the token from inside its own constructor, the way a factory whose constructor
/// launches a token would: the supply must land on the address under construction.
contract ConstructorDeployer {
    DogHoodToken public immutable token;

    constructor() {
        token = new DogHoodToken();
    }
}

/// @notice Edge cases and failure paths beyond `DogHoodToken.t.sol`: approval semantics, the
/// corner inputs of `transferFrom`, unknown calldata, and round-trip properties fuzzed with
/// `bound` so no run is discarded.
/// forge-config: default.fuzz.runs = 1000
contract DogHoodTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    DogHoodToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        vm.prank(deployer);
        token = new DogHoodToken();
    }

    function _fund(address to, uint256 amount) internal {
        vm.prank(deployer);
        token.transfer(to, amount);
    }

    /// @dev A non-zero address derived from a fuzzed seed, without discarding any run.
    function _addr(uint256 seed) internal pure returns (address) {
        return address(uint160(bound(seed, 1, type(uint160).max)));
    }

    // ---------------------------------------------------------------- deployment

    function test_deployFromAContractConstructorMintsToThatContract() public {
        ConstructorDeployer d = new ConstructorDeployer();
        assertEq(d.token().balanceOf(address(d)), SUPPLY);
        assertEq(d.token().totalSupply(), SUPPLY);
    }

    function test_supplyFitsComfortablyBelowOverflow() public view {
        // 1e27 is far below 2^256, so a holder can never overflow by receiving the whole supply twice over.
        assertLt(token.totalSupply(), type(uint256).max / 2);
        assertEq(token.totalSupply(), 1e27);
    }

    // ------------------------------------------------------------- approve semantics

    function test_approveOverwritesInsteadOfAdding() public {
        vm.startPrank(alice);
        token.approve(bob, 10 ether);
        token.approve(bob, 3 ether);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 3 ether, "second approve must replace the first");
    }

    function test_approveZeroClearsAllowance() public {
        vm.startPrank(alice);
        token.approve(bob, 10 ether);
        token.approve(bob, 0);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_approveIsNotBoundedByBalance() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, SUPPLY * 2));
        assertEq(token.allowance(alice, bob), SUPPLY * 2);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_approveDoesNotMoveTokens() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_allowanceIsDirectional() public {
        vm.prank(alice);
        token.approve(bob, 5 ether);
        assertEq(token.allowance(alice, bob), 5 ether);
        assertEq(token.allowance(bob, alice), 0);
    }

    function test_approveSelfThenTransferFromSelf() public {
        _fund(alice, 10 ether);
        vm.startPrank(alice);
        token.approve(alice, 4 ether);
        assertTrue(token.transferFrom(alice, bob, 4 ether));
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.allowance(alice, alice), 0);
    }

    /// @dev The owner spending its own tokens through transferFrom still needs an allowance.
    function test_revert_transferFromSelfWithoutApproval() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_revert_approveFromZeroAddress() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(bob, 1);
    }

    // ------------------------------------------------------- transferFrom corners

    function test_transferFromZeroAmountWithoutApprovalSucceeds() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 0));
        assertEq(token.balanceOf(carol), 0);
    }

    function test_transferFromToOwnerKeepsBalanceAndSpendsAllowance() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 6 ether);
        vm.prank(bob);
        token.transferFrom(alice, alice, 6 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 10 ether);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_maxMinusOneAllowanceIsDecremented() public {
        _fund(alice, 1);
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, bob), type(uint256).max - 2);
    }

    function test_revert_transferFromToZeroAddress() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 1 ether);
        assertEq(token.allowance(alice, bob), 10 ether, "a reverted transferFrom must not spend allowance");
    }

    function test_revert_transferFromZeroAddressOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(0), bob, 1);
        // With a zero amount the allowance check passes and the zero owner is refused as an approver.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
    }

    /// @dev The allowance is checked before the balance: a spender with neither sees the allowance error.
    function test_revert_allowanceCheckedBeforeBalance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_revert_transferMaxUint() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    function test_revert_transferSupplyPlusOne() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
    }

    function test_revert_transferFromZeroAddressSpender() public {
        _fund(alice, 10 ether);
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(0), 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    // ------------------------------------------------------------------- events

    function test_transferFromEmitsOnlyTransfer() public {
        _fund(alice, 10 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.recordLogs();
        vm.prank(bob);
        token.transferFrom(alice, carol, 4 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emits exactly one event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(address(uint160(uint256(logs[0].topics[1]))), alice);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), carol);
        assertEq(abi.decode(logs[0].data, (uint256)), 4 ether);
    }

    function test_zeroTransferStillEmits() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        token.transfer(bob, 0);
    }

    function test_revertedTransferEmitsNothing() public {
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (bob, 1)));
        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ------------------------------------------------------------ unknown calldata

    function test_revert_emptyCalldata() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok, "the token has no fallback");
    }

    function test_revert_unknownSelector() public {
        (bool ok, bytes memory ret) = address(token).call(hex"deadbeef");
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function test_revert_shortCalldataForTransfer() public {
        bytes memory data = abi.encodeCall(token.transfer, (alice, 1));
        bytes memory truncated = new bytes(data.length - 1);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = data[i];
        }
        vm.prank(deployer);
        (bool ok,) = address(token).call(truncated);
        assertFalse(ok, "truncated calldata must be refused");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_revert_increaseAllowanceDoesNotExist() public {
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeWithSignature("increaseAllowance(address,uint256)", bob, 1));
        assertFalse(ok);
        assertEq(token.allowance(alice, bob), 0);
    }

    // --------------------------------------------------------------------- fuzz

    /// @dev Round trip: a transfer out and the same amount back restores both balances exactly.
    function testFuzz_transferRoundTripRestoresBalances(uint256 seed, uint256 amount) public {
        address to = _addr(seed);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        vm.prank(to);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        if (to != deployer) assertEq(token.balanceOf(to), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A chain of hops conserves units: the last receiver holds what the first sender sent.
    function testFuzz_multiHopConservesAmount(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(carol, c);
        assertEq(token.balanceOf(deployer), SUPPLY - a);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(carol), c);
        assertEq(
            token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol), SUPPLY
        );
    }

    /// @dev Splitting a balance across two receivers in two calls moves exactly the split.
    function testFuzz_splitTransfers(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        vm.startPrank(deployer);
        token.transfer(alice, first);
        token.transfer(bob, total - first);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), first);
        assertEq(token.balanceOf(bob), total - first);
        assertEq(token.balanceOf(deployer), SUPPLY - total);
    }

    /// @dev Last approve wins, whatever came before, and approving the same value twice is idempotent.
    function testFuzz_approveLastWriteWins(uint256 seed, uint256 first, uint256 second) public {
        address spender = _addr(seed);
        vm.startPrank(alice);
        token.approve(spender, first);
        token.approve(spender, second);
        assertEq(token.allowance(alice, spender), second);
        token.approve(spender, second);
        assertEq(token.allowance(alice, spender), second);
        vm.stopPrank();
    }

    /// @dev Spending in two steps decrements the allowance by their sum, never more, never less.
    function testFuzz_allowanceDecrementsBySpent(uint256 held, uint256 allowed, uint256 x, uint256 y) public {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, held);
        x = bound(x, 0, allowed);
        y = bound(y, 0, allowed - x);
        _fund(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.startPrank(bob);
        token.transferFrom(alice, carol, x);
        token.transferFrom(alice, carol, y);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), allowed - x - y);
        assertEq(token.balanceOf(carol), x + y);
        assertEq(token.balanceOf(alice), held - x - y);
    }

    /// @dev With an unlimited allowance, any number of spends leaves it unlimited.
    function testFuzz_unlimitedAllowanceSurvivesSpends(uint256 held, uint256 x, uint256 y) public {
        held = bound(held, 0, SUPPLY);
        x = bound(x, 0, held);
        y = bound(y, 0, held - x);
        _fund(alice, held);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.startPrank(bob);
        token.transferFrom(alice, carol, x);
        token.transferFrom(alice, carol, y);
        vm.stopPrank();
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(carol), x + y);
    }

    /// @dev A transfer that fails changes nothing: balances before and after are identical.
    function testFuzz_failedTransferIsAtomic(uint256 held, uint256 seed) public {
        held = bound(held, 0, SUPPLY - 1);
        address to = _addr(seed);
        _fund(alice, held);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeCall(token.transfer, (to, held + 1)));
        assertFalse(ok);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A transferFrom that fails on the balance leaves the allowance untouched.
    function testFuzz_failedTransferFromKeepsAllowance(uint256 held, uint256 allowed) public {
        held = bound(held, 0, SUPPLY - 1);
        allowed = bound(allowed, held + 1, type(uint256).max);
        _fund(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        vm.prank(bob);
        (bool ok,) = address(token).call(abi.encodeCall(token.transferFrom, (alice, carol, held + 1)));
        assertFalse(ok);
        assertEq(token.allowance(alice, bob), allowed);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(carol), 0);
    }

    /// @dev Any address other than zero may receive, including contracts and precompile addresses.
    function testFuzz_anyNonZeroAddressCanReceive(uint256 seed, uint256 amount) public {
        address to = _addr(seed);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) assertEq(token.balanceOf(deployer), SUPPLY);
        else assertEq(token.balanceOf(to), amount);
    }

    /// @dev Nobody, whoever they are, can call anything that grows the supply.
    function testFuzz_noCallerCanMint(uint256 seed, uint256 amount) public {
        address caller = _addr(seed);
        vm.startPrank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", caller, amount));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("mint(uint256)", amount));
        assertFalse(ok);
        vm.stopPrank();
        assertEq(token.totalSupply(), SUPPLY);
        if (caller != deployer) assertEq(token.balanceOf(caller), 0);
    }
}
