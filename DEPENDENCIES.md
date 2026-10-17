# Vendored dependencies

All imported dependency source is included as ordinary files. There are no submodules, package-install steps, linked external libraries, compiler binaries, or dependencies outside the repository.

| Dependency | Pinned upstream | Included material | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | [v5.1.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) | ERC20, SafeERC20, ReentrancyGuard, and their necessary interfaces/utilities | MIT, `lib/openzeppelin-contracts/LICENSE` |
| forge-std | [v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | `src/` test and script utilities | MIT or Apache-2.0, licenses in `lib/forge-std/` |

Downloaded archive SHA-256 values, for provenance:

```text
OpenZeppelin v5.1.0: 8a3b08cfc756437ba3343901565b18182adb42ec1e621960240a19da5d738686
forge-std v1.9.7:    45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94
```

Archives were obtained from each repository's `codeload.github.com` tag archive. Only the source files and licenses are delivered; builds do not download these archives. Production library calls are internal/inlined. Foundry supplies the compiler pinned in `foundry.toml`.
