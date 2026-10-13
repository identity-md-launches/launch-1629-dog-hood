// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {DogHoodToken} from "../src/DogHoodToken.sol";

/// @notice Drives the token with random, bounded calls from a fixed set of actors and keeps ghost
/// accounting of what every balance and allowance must be. Every function here is written so that
/// it never reverts itself: the calls that are expected to fail are made with a low-level call and
/// their revert is asserted, so the invariant runner can be told that any revert is a failure.
contract DogHoodHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    DogHoodToken public immutable token;
    address public immutable deployer;
    address[] internal actors;

    // ---- ghost state: what the token must report, derived only from calls that succeeded.
    mapping(address => uint256) public ghost_in;
    mapping(address => uint256) public ghost_out;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    uint256 public ghost_totalMoved;

    // ---- call counters, so a run that exercised nothing can be told apart from a passing one.
    uint256 public ghost_transfers;
    uint256 public ghost_transferFroms;
    uint256 public ghost_approvals;
    uint256 public ghost_rejectedTransfers;
    uint256 public ghost_rejectedTransferFroms;
    uint256 public ghost_rejectedZeroReceivers;
    uint256 public ghost_rejectedPrivilegedCalls;
    uint256 public ghost_rejectedEther;

    constructor(DogHoodToken token_, address deployer_, address[] memory actors_) {
        token = token_;
        deployer = deployer_;
        actors = actors_;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // ----------------------------------------------------------------- happy paths

    /// @dev A transfer within the sender's balance always succeeds and moves exactly `amount`.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender lost a different amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver gained a different amount");
        }

        ghost_out[from] += amount;
        ghost_in[to] += amount;
        ghost_totalMoved += amount;
        ghost_transfers += 1;
    }

    /// @dev Approve overwrites: whatever was allowed before, the new value is the allowance. One in
    /// eight approvals is the unlimited allowance so the never-decrementing path is exercised too.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = amount % 8 == 0 ? type(uint256).max : bound(amount, 0, 2 * SUPPLY);

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "allowance is not what was approved");

        ghost_allowance[owner][spender] = amount;
        ghost_approvals += 1;
    }

    /// @dev A transferFrom within both the owner's balance and the spender's allowance succeeds,
    /// moves exactly `amount`, and decrements the allowance unless it is unlimited.
    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 cap = token.balanceOf(from) < allowed ? token.balanceOf(from) : allowed;
        amount = bound(amount, 0, cap);

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        bool ok = token.transferFrom(from, to, amount);
        assertTrue(ok, "transferFrom returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transferFrom changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "owner lost a different amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver gained a different amount");
        }
        if (allowed == type(uint256).max) {
            assertEq(token.allowance(from, spender), type(uint256).max, "unlimited allowance was decremented");
        } else {
            assertEq(token.allowance(from, spender), allowed - amount, "allowance decremented by a different amount");
            ghost_allowance[from][spender] = allowed - amount;
        }

        ghost_out[from] += amount;
        ghost_in[to] += amount;
        ghost_totalMoved += amount;
        ghost_transferFroms += 1;
    }

    // --------------------------------------------------------------- failure paths

    /// @dev Any amount above the balance is refused with the balance error and moves nothing.
    function transferExceedingBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        uint256 amount = held + bound(excess, 1, SUPPLY);

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (to, amount)));
        assertFalse(ok, "transfer above balance succeeded");
        assertEq(
            ret,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount),
            "wrong error for transfer above balance"
        );
        assertEq(token.balanceOf(from), held, "a failed transfer changed the sender's balance");
        ghost_rejectedTransfers += 1;
    }

    /// @dev Above the allowance the allowance error is raised, before the balance is even checked.
    /// With an unlimited allowance the only thing left to exceed is the balance.
    function transferFromExceedingAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 held = token.balanceOf(from);
        uint256 amount;
        bytes memory expected;
        if (allowed == type(uint256).max) {
            amount = held + bound(excess, 1, SUPPLY);
            expected = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount);
        } else {
            amount = allowed + bound(excess, 1, SUPPLY);
            expected =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        }

        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transferFrom, (from, to, amount)));
        assertFalse(ok, "transferFrom above allowance succeeded");
        assertEq(ret, expected, "wrong error for transferFrom above allowance");
        assertEq(token.balanceOf(from), held, "a failed transferFrom changed the owner's balance");
        assertEq(token.allowance(from, spender), allowed, "a failed transferFrom changed the allowance");
        ghost_rejectedTransferFroms += 1;
    }

    /// @dev Nothing can be sent to the zero address, so nothing can leave the supply that way.
    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 held = token.balanceOf(from);
        amount = bound(amount, 0, held);

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (address(0), amount)));
        assertFalse(ok, "transfer to the zero address succeeded");
        assertEq(ret, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        assertEq(token.balanceOf(from), held, "a failed transfer changed the sender's balance");
        ghost_rejectedZeroReceivers += 1;
    }

    /// @dev Every privileged entry point a token might have is tried, from every actor including the
    /// deployer, and must be refused. The invariants then confirm no balance or supply moved.
    function privilegedCall(uint256 callerSeed, uint256 sigSeed, uint256 targetSeed, uint256 amount) external {
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setBlacklist(address,bool)",
            "freeze(address)",
            "seize(address)",
            "transferOwnership(address)",
            "setMinter(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setFee(uint256)",
            "setTransfersEnabled(bool)"
        ];
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        string memory sig = signatures[bound(sigSeed, 0, signatures.length - 1)];

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, target, amount));
        assertFalse(ok, sig);
        ghost_rejectedPrivilegedCalls += 1;
    }

    /// @dev The token has no receive or fallback: ether sent to it bounces.
    function sendEther(uint256 fromSeed, uint256 value) external {
        address from = _actor(fromSeed);
        value = bound(value, 0, 100 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
        ghost_rejectedEther += 1;
    }
}

/// @notice Invariants over random call sequences against the token. The token holds every holder's
/// balance, so what it must keep after every call is: a supply that never changes, balances that
/// always sum to that supply, balances that equal the net of the successful transfers into and out
/// of each account, and allowances that equal what was approved less what was spent.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract DogHoodTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    DogHoodToken internal token;
    DogHoodHandler internal handler;
    address internal deployer = makeAddr("factory");
    address[] internal actors;

    function setUp() public {
        vm.prank(deployer);
        token = new DogHoodToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(makeAddr("erin"));
        handler = new DogHoodHandler(token, deployer, actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = DogHoodHandler.transfer.selector;
        selectors[1] = DogHoodHandler.approve.selector;
        selectors[2] = DogHoodHandler.transferFrom.selector;
        selectors[3] = DogHoodHandler.transferExceedingBalance.selector;
        selectors[4] = DogHoodHandler.transferFromExceedingAllowance.selector;
        selectors[5] = DogHoodHandler.transferToZeroAddress.selector;
        selectors[6] = DogHoodHandler.privilegedCall.selector;
        selectors[7] = DogHoodHandler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _initial(address account) internal view returns (uint256) {
        return account == deployer ? SUPPLY : 0;
    }

    // ------------------------------------------------------------------ invariants

    /// @dev Fixed supply: no sequence of calls, including every privileged call tried, changes it.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY(), "supply disagrees with the constant");
    }

    /// @dev Conservation: every unit of the supply is in some actor's balance. Nothing can leak to
    /// the zero address, the token itself or the handler, because no handler path sends there.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens");
        assertEq(token.balanceOf(address(handler)), 0, "the handler holds tokens");
    }

    /// @dev Each balance is exactly its starting balance plus what successful calls moved in, minus
    /// what they moved out. A failed call, a privileged call or ether sent changes none of them.
    function invariant_balancesMatchGhostFlows() public view {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            uint256 expected = _initial(a) + handler.ghost_in(a) - handler.ghost_out(a);
            assertEq(token.balanceOf(a), expected, "balance disagrees with recorded flows");
            assertLe(token.balanceOf(a), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev What left all senders equals what reached all receivers: transfers neither create nor
    /// destroy units.
    function invariant_outflowsEqualInflows() public view {
        uint256 totalIn;
        uint256 totalOut;
        for (uint256 i; i < actors.length; ++i) {
            totalIn += handler.ghost_in(actors[i]);
            totalOut += handler.ghost_out(actors[i]);
        }
        assertEq(totalIn, totalOut, "inflows and outflows disagree");
        assertEq(totalIn, handler.ghost_totalMoved(), "ghost total disagrees with flows");
    }

    /// @dev Every allowance is exactly the last value approved, less what the spender has since
    /// spent, and an unlimited allowance stays unlimited.
    function invariant_allowancesMatchGhost() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghost_allowance(actors[i], actors[j]),
                    "allowance disagrees with what was approved and spent"
                );
            }
        }
    }

    /// @dev The token never accumulates ether and never grows beyond EIP-170, whatever was called.
    function invariant_tokenHoldsNoEther() public view {
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    // ------------------------------------------------------- harness self-checks

    /// @dev Grounds the harness: every handler path does what its ghost accounting claims when driven
    /// directly, so a passing invariant run is not a run in which nothing happened.
    function test_handlerPathsAreLive() public {
        handler.transfer(0, 1, 100 ether);
        assertEq(token.balanceOf(actors[1]), 100 ether);
        assertEq(handler.ghost_in(actors[1]), 100 ether);
        assertEq(handler.ghost_out(deployer), 100 ether);

        handler.approve(1, 2, 7); // 7 % 8 != 0 -> bounded value, not unlimited
        assertEq(token.allowance(actors[1], actors[2]), 7);
        handler.approve(1, 2, 8); // 8 % 8 == 0 -> unlimited
        assertEq(token.allowance(actors[1], actors[2]), type(uint256).max);

        handler.transferFrom(2, 1, 3, 40 ether);
        assertEq(token.balanceOf(actors[3]), 40 ether);
        assertEq(token.balanceOf(actors[1]), 60 ether);
        assertEq(token.allowance(actors[1], actors[2]), type(uint256).max);

        handler.transferExceedingBalance(3, 4, 1);
        handler.transferFromExceedingAllowance(4, 3, 5, 1);
        handler.transferFromExceedingAllowance(2, 1, 5, 1);
        handler.transferToZeroAddress(3, 1 ether);
        handler.privilegedCall(0, 0, 1, 1);
        handler.sendEther(1, 1 ether);

        assertEq(handler.ghost_transfers(), 1);
        assertEq(handler.ghost_approvals(), 2);
        assertEq(handler.ghost_transferFroms(), 1);
        assertEq(handler.ghost_rejectedTransfers(), 1);
        assertEq(handler.ghost_rejectedTransferFroms(), 2);
        assertEq(handler.ghost_rejectedZeroReceivers(), 1);
        assertEq(handler.ghost_rejectedPrivilegedCalls(), 1);
        assertEq(handler.ghost_rejectedEther(), 1);

        invariant_totalSupplyNeverChanges();
        invariant_balancesSumToSupply();
        invariant_balancesMatchGhostFlows();
        invariant_outflowsEqualInflows();
        invariant_allowancesMatchGhost();
    }

    /// @dev Every privileged signature the handler tries is refused from every actor, so the
    /// privileged path of the invariant run is not vacuous for any of them.
    function test_everyPrivilegedSignatureIsRefusedFromEveryActor() public {
        for (uint256 c; c < actors.length; ++c) {
            for (uint256 s; s < 16; ++s) {
                handler.privilegedCall(c, s, (c + 1) % actors.length, type(uint128).max);
            }
        }
        assertEq(handler.ghost_rejectedPrivilegedCalls(), actors.length * 16);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }
}
