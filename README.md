# Dog hood (DOG)

A fixed-supply ERC-20 token for a custom token launch on Robinhood Chain (chain id 4663).

| Property | Value |
| --- | --- |
| Solidity contract | `DogHoodToken` (`src/DogHoodToken.sol`) |
| `name()` | `Dog hood` |
| `symbol()` | `DOG` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 DOG = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minted to | `msg.sender` of the constructor, once, in the constructor |

## Behaviour

- The whole supply is minted in the constructor to the deployer. Nothing can mint afterwards:
  there is no `mint`, no minter role, no owner and no upgrade path.
- There is no burn function. ERC-20 refuses transfers to the zero address, so `totalSupply()`
  is constant for the life of the contract.
- Transfers, approvals and `transferFrom` are the unmodified OpenZeppelin v5.1.0 `ERC20`.
  No fee, tax, reflection, blocklist, pause or freeze exists. Only a holder, or a spender the
  holder approved, can move a balance.
- The contract has no `receive` or `fallback`, so it refuses ether.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.

## Launch assumptions

- The launch factory deploys the token with CREATE2 through `ProjectFactory.launchCustom`, so
  `msg.sender` in the constructor is the factory and the factory receives the whole supply. The
  factory then forwards the swarm's 10%, seeds the pool with the requester's `poolBps` share and
  sends the remainder to `economics.remainderTo`. Because the token takes no fee on any transfer,
  every one of those flows arrives whole.
- The constructor takes no arguments, calls no other contract and does not need any address to
  have code, so it deploys on an empty chain and the manifest's `constructorArgs` is `[]`.
- Manifest values this contract fixes: `token.contract = "DogHoodToken"`, `token.name = "Dog hood"`,
  `token.symbol = "DOG"`, `token.decimals = 18`,
  `token.totalSupply = "1000000000000000000000000000"`.
- Pool, economics and fee values (pair IMD, fee 12500, tick spacing 60, pool share 88%, opening
  cap 2,500 IMD, remainder to `0x12a7aad083cef06fef7c295514b52fc8bc81960d`) are the launch's and
  are written by the manifest step, not by this repository. No `launch.json` is included here.
- No application contracts accompany the token.

## Operational responsibilities

- **Nobody holds a privileged role.** There is no owner to rotate, no key to secure beyond the
  holders' own, and no parameter to set after launch. The "After launch" list is empty.
- **The deployer's supply is the launch's.** Whoever deploys the contract holds all 1,000,000,000
  DOG until they move it. In the launch that is the factory, which pays everything out in the
  same transaction.
- **Holders are responsible for their own approvals.** An unlimited allowance is honoured exactly
  as ERC-20 specifies and is never decremented; approve only what a spender needs.
- **The token cannot be paused or recovered.** Tokens sent to a wrong address, or to a contract
  that cannot move them, are not recoverable by anyone.

## Open deployment choices

None. The brief fixes the name, symbol, decimals and supply, and the launch fixes the chain, pair,
fee, tick spacing and economics. No value in this repository is a placeholder.

## Dependencies

Vendored as plain files under `lib/` (no git submodules):

- `lib/forge-std` — forge-std v1.9.7 (`src/`, licences, `package.json`), test framework only.
- `lib/openzeppelin-contracts` — OpenZeppelin Contracts v5.1.0, the `token/`, `interfaces/` and
  `utils/` trees and the licence.

Remappings are in `remappings.txt`.

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, the optimizer at 200 runs and
`bytecode_hash = "none"` so the built bytecode is reproducible without a metadata hash. `ffi` is
off and no filesystem permissions are granted.

The tests in `test/DogHoodToken.t.sol` cover:

- metadata, supply, and that the constructor mints exactly once to `msg.sender` (including via a
  CREATE2 factory stub, the way the launch deploys);
- successful transfer, zero transfer, whole-balance transfer, self-transfer, approve and
  `transferFrom`, and the unlimited-allowance path;
- failure cases: insufficient balance, empty account, zero-address recipient, insufficient or
  missing allowance, balance below an approved amount, zero spender;
- that no mint, burn, owner, pause or blocklist function exists for anyone, that ether is refused,
  and that the runtime has no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`;
- fuzz tests for supply conservation and for the balance and allowance bounds.

Tests read no environment variables and do not depend on the calling address, so they pass in
any order and in parallel.

## Security notes

This token is a thin wrapper over an audited OpenZeppelin implementation with no added logic, so
the remaining review items are the launch's: the pool seeding, the distributor and the factory are
outside this repository. Passing tests are not an audit; an independent adversarial review is still
the appropriate step before any contract that holds other people's funds is released.
