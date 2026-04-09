# Code-Only Audit of `src/modules`

## Highest-Confidence Findings

### 3. `websocket` strictness issues are mostly fixed, but broader protocol verification still remains

Originally observed problems:

- Client handshake validated `101` and `Sec-WebSocket-Accept`, but not `Upgrade: websocket` and `Connection: Upgrade`
- Server upgrade path did not enforce `GET`
- Server upgrade path would send a chosen subprotocol without validating that the client offered it
- Frame masking was parsed but not enforced, so protocol-invalid peer behavior was not rejected

Current status:

- the current worktree now enforces these checks directly in the implementation
- focused regression tests cover invalid handshake headers, invalid
  subprotocol negotiation, masking violations, fragmented control frames, and
  reserved-bit misuse

Remaining tasks:

- broaden coverage further for close-handshake behavior, fragmentation flows,
  ping/pong, and compression paths
- verify the stricter behavior across supported capability combinations

Relevant code:

- `src/modules/websocket.luau`
- `src/modules/websocket.test.luau`

### 4. `eryxdoc` reports parse failures poorly

`src/modules/eryxdoc/content/modules.luau` prints parse errors, then throws `error("")`, which destroys useful error context for programmatic callers.

## Module-by-Module Assessment

Assessments use this rough scale:

- `Good`: no clear breakage found from code review; may still have normal residual risk
- `Mixed`: usable, but with notable risks, gaps, or missing coverage
- `Weak`: significant design, testing, or implementation concerns
- `Broken`: high-confidence defect present

### Top-Level Native/System Modules

#### `_ffi`

Assessment: `Mixed`

- Windows-only by build.
- Type/API layer is clear and intentionally low-level.
- FFI is inherently unsafe; the module honestly reflects that.
- No direct tests found.
- Main risk is operational safety and platform-specific drift.

Files:

- `src/modules/_ffi.luau`
- `src/modules/_ffi.cpp`
- `src/modules/_ffi.hpp`

### Top-Level Pure Luau Utility Modules

#### `pprint`

Assessment: `Mixed`

- Utility module with several internal TODO comments.
- Not clearly broken, but not polished.
- No direct tests found.

Files:

- `src/modules/pprint.luau`

#### `websocket`

Assessment: `Mixed`

- Ambitious implementation with client, server, fragmentation, ping/pong, and compression support.
- The highest-confidence protocol correctness issues from this audit have now been addressed in the current worktree.
- Remaining risk is broader protocol completeness and capability-matrix verification rather than the original missing checks.
- Test coverage is materially better now, but still not complete enough to treat the module as low-risk.

Files:

- `src/modules/websocket.luau`
- `src/modules/websocket.test.luau`

#### `webview`

Assessment: `Mixed`

- Windows-only native module with a substantial implementation.
- Feature surface is broad and useful.
- No direct tests found.
- Main concern is lack of automated coverage plus platform-specific complexity.

Files:

- `src/modules/webview.luau`
- `src/modules/webview.cpp`
