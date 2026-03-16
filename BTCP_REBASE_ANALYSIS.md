# BTCP Rebase with zkSNARKs — Failure Analysis & Modern Solutions

## Executive Summary

The BTCP (Bitcoin Private) Rebase project attempted to merge modern Bitcoin Core (v0.17.x) infrastructure with Zcash's Sprout-era zkSNARK privacy features. The project **fails to build on modern systems** due to a combination of outdated dependencies, C++ standard library changes, Boost API breakage, and an obsolete Rust toolchain. This document catalogs every identified failure, the fixes applied, and outlines a path forward using modern zkSNARK technology.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Build Failures Identified](#build-failures-identified)
3. [Fixes Applied](#fixes-applied)
4. [Remaining Issues](#remaining-issues)
5. [Root Cause: Why the Rebase Failed](#root-cause-why-the-rebase-failed)
6. [Modern Solutions Available Today](#modern-solutions-available-today)
7. [Recommended Path Forward](#recommended-path-forward)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│         BTCP Rebase Architecture                │
├─────────────────────────────────────────────────┤
│  Bitcoin Core 0.17.x (C++11)                    │
│  ├── SegWit, HD Wallets, Modern P2P             │
│  └── Consensus, Validation, RPC, Wallet         │
├─────────────────────────────────────────────────┤
│  Zcash Sprout Privacy Layer                     │
│  ├── JoinSplit Transactions (2-in, 2-out)       │
│  ├── Shielded Notes + Encryption                │
│  ├── Incremental Merkle Trees (depth 29)        │
│  └── 911MB Proving/Verifying Key Parameters     │
├─────────────────────────────────────────────────┤
│  zkSNARK Proving System                         │
│  ├── libsnark (C++) — r1cs_ppzksnark            │
│  ├── alt_bn128 Elliptic Curve (Pairing-based)   │
│  └── librustzcash 0.1 (Rust 1.16.0)            │
├─────────────────────────────────────────────────┤
│  Dependencies                                   │
│  ├── Boost, OpenSSL, Libevent, libsodium        │
│  ├── GMP/GMPXX (Big Integer Arithmetic)         │
│  ├── OpenMP (Parallel Proof Generation)          │
│  └── Rust 1.16.0 (2017) for librustzcash        │
└─────────────────────────────────────────────────┘
```

**Key Design Decisions:**
- Uses **Sprout** (original Zcash) proof system, NOT Sapling/Groth16
- Proof sizes: ~296 bytes (compressed) — much larger than Groth16's ~192 bytes
- Proving key: ~740MB, Verifying key: ~171MB (vs Sapling's ~50MB total)
- Trusted setup ceremony required (Zcash Powers of Tau)

---

## Build Failures Identified

### 1. `configure.ac`: libgmp Detection Failure (CRITICAL)

**Error:**
```
conftest.cpp:81:18: error: structured binding declaration cannot have type 'int'
   81 |   extern "C" int [__gmpn_sub_n] ();
```

**Root Cause:** The `AC_CHECK_LIB` macro used double M4 brackets `[[__gmpn_sub_n]]` which produces `[__gmpn_sub_n]` in the generated C++ test. Modern compilers (GCC 10+/Clang 13+) with C++17 awareness interpret `int [name]` as a structured binding declaration, causing a parse error.

**Impact:** Configure fails, preventing any build from proceeding. libgmp is required by libsnark for big integer arithmetic in elliptic curve operations.

---

### 2. Missing C++ Standard Library Headers (CRITICAL)

**Files affected:**
- `src/httpserver.cpp` — missing `#include <deque>`
- `src/support/lockedpool.cpp` — missing `#include <stdexcept>`
- `src/crypto/equihash.h` — missing `#include <stdexcept>`

**Root Cause:** Older GCC versions (< 11) transitively included these headers through other standard library headers. GCC 11+ and Clang 14+ removed these implicit inclusions, following strict C++ standard compliance.

**Impact:** Compilation fails with "not a member of 'std'" errors for `std::deque`, `std::runtime_error`, and `std::invalid_argument`.

---

### 3. Boost 1.73+ Bind Placeholder Ambiguity (CRITICAL)

**Error:**
```
validation.cpp:2378:97: error: '_1' was not declared in this scope
```

**Files affected:**
- `src/validation.cpp`
- `src/validationinterface.cpp`
- `src/torcontrol.cpp`
- `src/rpc/server.cpp`
- Multiple Qt GUI files

**Root Cause:** Boost 1.73 (released April 2020) moved bind placeholders (`_1`, `_2`, etc.) from the global namespace into `boost::placeholders`. The old `#include <boost/bind.hpp>` header was deprecated in favor of `#include <boost/bind/bind.hpp>`. Code using bare `_1`, `_2` without qualification became ambiguous because multiple namespaces (`std::placeholders`, `boost::placeholders`, `boost::mp11`) define these symbols.

**Impact:** All files using `boost::bind` with unqualified placeholders fail to compile.

---

### 4. libsnark gtest Build Failure (HIGH)

**Error:**
```
libsnark/algebra/curves/tests/test_bilinearity.cpp:13:10: fatal error: gtest/gtest.h: No such file or directory
```

**Root Cause:** The libsnark `Makefile` `all` target includes gtest-dependent test files unless `NO_GTEST=1` is passed. The BTCP build configuration passed `NO_COMPILE_LIBGTEST=1` (which only prevents compiling gtest from source) but not `NO_GTEST=1` (which excludes gtest test targets entirely). Additionally, the build invoked the default `all` target instead of the `lib` target.

**Impact:** libsnark.a fails to build because test object files can't compile without gtest headers.

---

### 5. Rust 1.16.0 Toolchain Obsolescence (CRITICAL)

**Root Cause:** The `depends/packages/rust.mk` pins Rust version 1.16.0 (released March 2017). This version:
- Has known security vulnerabilities (CVE-2019-12083, CVE-2020-36323, etc.)
- Binary distributions may not run on modern Linux (glibc 2.34+ incompatibility)
- Cannot build crates that require Rust 2018 edition or later
- Download URLs at `static.rust-lang.org` may have reduced availability

**Impact:** The `depends` build system cannot build `librustzcash`, which is required for linking `bitcoind`, `bitcoin-cli`, and all other binaries. This is the **final blocking issue** after all compilation fixes.

---

### 6. librustzcash Linkage Failure (CRITICAL)

**Error:**
```
/usr/bin/ld: cannot find -lrustzcash: No such file or directory
```

**Root Cause:** `librustzcash.a` is not present because it must be built via the `depends` system using the pinned (and obsolete) Rust toolchain. The `configure.ac` unconditionally sets `RUST_LIBS="-lrustzcash"` and `LIBZCASH_LIBS` includes `$RUST_LIBS`, causing all binaries to require this library.

**Impact:** No binaries can be linked. This is the ultimate build-stopper.

---

### 7. Automake Warnings (LOW)

**Warnings:**
```
src/Makefile.zcash.include:19: warning: variable 'zcash_CreateJoinSplit_SOURCES' is defined but no program or library has 'zcash_CreateJoinSplit' as canonical name
src/Makefile.am:607: warning: variable 'libzcash_a_LDFLAGS' is defined but no program or library has 'libzcash_a' as canonical name
```

**Root Cause:**
- `zcash_CreateJoinSplit` was removed from `noinst_PROGRAMS` (commented out) due to failing linkage, but its variable definitions were left in place.
- `libzcash_a_LDFLAGS` is meaningless for a static library archive (`.a` files don't link).

**Impact:** Build warnings only, no functional impact.

---

### 8. OpenSSL 3.0 API Deprecations (POTENTIAL)

The codebase uses OpenSSL for cryptographic operations. OpenSSL 3.0 (Ubuntu 22.04+) deprecated many low-level APIs that were available in OpenSSL 1.1.x. While the current build succeeds past configure, some code paths may use deprecated EVP functions that could fail at runtime or in future compiler versions with `-Werror`.

---

## Fixes Applied

| # | File | Fix | Status |
|---|------|-----|--------|
| 1 | `configure.ac` | Changed `[[__gmpn_sub_n]]` to `[__gmpn_sub_n]` in `AC_CHECK_LIB` | ✅ Fixed |
| 2 | `src/httpserver.cpp` | Added `#include <deque>` | ✅ Fixed |
| 3 | `src/support/lockedpool.cpp` | Added `#include <stdexcept>` | ✅ Fixed |
| 4 | `src/crypto/equihash.h` | Added `#include <stdexcept>` | ✅ Fixed |
| 5 | `src/validation.cpp` | Added `#include <boost/bind/bind.hpp>` and `using namespace boost::placeholders` | ✅ Fixed |
| 6 | `src/validationinterface.cpp` | Added `#include <boost/bind/bind.hpp>` and `using namespace boost::placeholders` | ✅ Fixed |
| 7 | `src/torcontrol.cpp` | Updated `#include <boost/bind/bind.hpp>` and `using namespace boost::placeholders` | ✅ Fixed |
| 8 | `src/rpc/server.cpp` | Updated `#include <boost/bind/bind.hpp>` and `using namespace boost::placeholders` | ✅ Fixed |
| 9 | `src/Makefile.am` | Added `NO_GTEST=1` to `LIBSNARK_CONFIG_FLAGS`; changed snark build target to `lib` | ✅ Fixed |
| 10 | `src/Makefile.zcash.include` | Commented out orphaned `zcash_CreateJoinSplit` variables | ✅ Fixed |
| 11 | `src/Makefile.am` | Removed meaningless `libzcash_a_LDFLAGS` for static library | ✅ Fixed |
| 12 | `depends/packages/rust.mk` | Updated Rust version from 1.16.0 to 1.32.0 with verified SHA256 hashes | ✅ Updated |

**Build Status After Fixes:**
- ✅ `./autogen.sh` — passes with no warnings
- ✅ `./configure` — succeeds (libgmp detected correctly)
- ✅ Compilation — all C++ source files compile successfully
- ✅ libsnark.a — builds without gtest errors
- ❌ Linking — fails due to missing `librustzcash.a` (requires `depends` build)

---

## Remaining Issues

### Cannot Resolve Without Major Refactoring

1. **librustzcash dependency** — Requires running the full `depends` build system which downloads and compiles Rust + librustzcash from source. The pinned librustzcash commit (91348647) is from early 2018 and may have compatibility issues even with Rust 1.32.0.

2. **Qt GUI files** — Multiple Qt source files (`bitcoingui.cpp`, `walletmodel.cpp`, `clientmodel.cpp`, etc.) have the same Boost bind placeholder issue. These were not fixed since the build was configured with `--without-gui`, but would need the same fix pattern for GUI builds.

3. **Z-address functionality** — Per the README: "Z addresses, wallet code, and tests are not fully working yet and should be considered unstable."

4. **Consensus rules incomplete** — Per the README: "not all consensus rules have been implemented."

5. **CreateJoinSplit tool** — Disabled due to unresolved linkage issues with `util.h` includes.

---

## Root Cause: Why the Rebase Failed

The BTCP Rebase failed for **five fundamental reasons**:

### 1. Technology Stack Mismatch
The project attempted to graft Zcash's 2016-era Sprout privacy system onto Bitcoin Core 0.17's 2018-era codebase. These two codebases had diverged significantly over 3 years, creating integration friction at every level — from build systems to consensus logic to wallet code.

### 2. Dependency Obsolescence
The project pinned to extremely specific and old versions:
- **Rust 1.16.0** (March 2017) — 9 years old, incompatible with modern systems
- **librustzcash 0.1** — Pre-release quality, tied to old Rust
- **libsnark** — Vendored copy from 2016, no upstream maintenance
- **Boost/OpenSSL/GCC** — assumed older versions that have since had breaking API changes

### 3. Sprout Protocol Limitations
The Sprout proof system has inherent disadvantages that made the project impractical:
- **911MB parameter files** required at runtime
- **~37 seconds** to generate a single proof on consumer hardware
- **Memory-intensive** — requires 1.5GB+ RAM for proof generation
- **Trusted setup** — requires ceremony, cannot be updated without new ceremony

### 4. Upstream Divergence
By the time BTCP Rebase was being developed (2018), Zcash was already transitioning to Sapling (activated October 2018), making the Sprout integration obsolete before completion.

### 5. Maintenance Gap
The last meaningful commit was in October 2018. Without continuous maintenance, the codebase couldn't keep up with:
- GCC/Clang compiler updates (C++17 features, stricter compliance)
- Boost 1.73+ API changes (bind placeholder namespacing)
- OpenSSL 3.0 deprecations
- Linux glibc updates (breaking old Rust binary compatibility)

---

## Modern Solutions Available Today

### Option A: Groth16 via bellman (Recommended for Sprout-compatible approach)

**What:** Replace libsnark's ppzkSNARK with Groth16 (as Zcash did in the Sapling upgrade).

**Advantages:**
- Proof size: 192 bytes (vs ~296 bytes with Sprout)
- Proving time: ~7 seconds (vs ~37 seconds)
- Verification time: ~10ms (vs ~10ms, similar)
- Parameter size: ~50MB (vs ~911MB)
- Mature Rust implementation via `bellman` crate

**Implementation:**
```
librustzcash (modern) → bellman → bls12_381 curve
```

**Effort:** Major refactoring required. Would need to:
1. Replace libsnark with bellman
2. Update circuit definitions from R1CS gadgetlib1 to bellman's Circuit trait
3. Implement Sapling-style note commitment tree
4. New parameter generation (Powers of Tau ceremony or use Zcash's)

### Option B: Halo 2 (Zero-Knowledge without Trusted Setup)

**What:** Use Zcash's Halo 2 proving system which eliminates the trusted setup entirely.

**Advantages:**
- No trusted setup ceremony required
- Recursive proof composition
- IPA-based (Inner Product Argument)
- Actively maintained by Electric Coin Company
- Used in Zcash Orchard (NU5, activated May 2022)

**Implementation:**
```
halo2_proofs crate → Pasta curves (Pallas/Vesta)
```

**Effort:** Complete rewrite of the privacy layer. Would need to:
1. Design new circuit using Halo 2's PLONKish arithmetization
2. Implement Orchard-style notes and commitments
3. Replace JoinSplit transactions with Orchard Actions
4. No external parameters needed (self-referencing proofs)

### Option C: Integrate with Modern Zcash Codebase

**What:** Instead of rebasing Bitcoin Core + old Zcash, fork modern zcashd (v5.x+) which already includes Sprout, Sapling, AND Orchard.

**Advantages:**
- All three proof systems already integrated
- Actively maintained by Zcash developers
- Modern Rust toolchain
- Battle-tested on mainnet

**Effort:** Medium. Would need to:
1. Fork zcashd 5.x
2. Apply Bitcoin Private's consensus parameter changes
3. Implement BTCP-specific fork logic
4. Test extensively

### Option D: Use zcash-primitives Rust Crate

**What:** Use the `zcash_primitives` Rust crate as a library for privacy features, keeping the Bitcoin Core base.

```toml
[dependencies]
zcash_primitives = "0.13"
zcash_proofs = "0.13"
bellman = "0.14"
```

**Advantages:**
- Clean separation of concerns
- Bitcoin Core stays modern and maintainable
- Privacy features provided by maintained Rust libraries
- Supports Sapling and Orchard out of the box

**Effort:** Significant but well-structured:
1. Create Rust FFI bridge to Bitcoin Core C++ codebase
2. Use zcash_primitives for note/payment creation
3. Use zcash_proofs for proof generation/verification
4. Implement transaction format extensions in Bitcoin Core

---

## Recommended Path Forward

### Short-term (Get it building):
1. ✅ Apply the compilation fixes in this PR
2. Run the full `depends` build with updated Rust 1.32.0
3. Verify librustzcash builds and links correctly
4. Fix remaining Qt GUI files for Boost bind placeholder issue
5. Run the test suite and fix any remaining failures

### Medium-term (Modernize the proof system):
1. **Replace libsnark with bellman** — Port the JoinSplit circuit from libsnark's gadgetlib1 to bellman's Circuit trait
2. **Update librustzcash** to a modern version that supports both Sprout verification (for backward compatibility) and Sapling proving
3. **Update Rust toolchain** to current stable (1.75+)
4. **Update C++ standard** from C++11 to C++17

### Long-term (Full modernization):
1. **Adopt Halo 2** for trustless proof generation
2. **Migrate to Orchard** note format (smaller, faster, no trusted setup)
3. **Keep Bitcoin Core base current** (v25+ for taproot, etc.)
4. Implement proper **Sapling/Orchard transaction types** alongside existing JoinSplit

---

## Appendix: Verified Build Environment

Successfully tested compilation (pre-linking) on:
- **OS:** Ubuntu 24.04 (Noble)
- **Compiler:** GCC 13.3.0
- **Boost:** 1.83.0
- **OpenSSL:** 3.0.13
- **libsodium:** 1.0.18
- **libgmp:** 6.3.0
- **Autotools:** autoconf 2.71, automake 1.16.5

---

*Analysis performed March 2026. For questions or contributions, please open an issue in the repository.*
