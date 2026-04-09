# Prioritized Remediation Plan for `src/modules`

This plan is derived from the code-only audit in [AUDIT_CODE_MODULES.md](C:/Users/Emma/Desktop/luau/embed_test/AUDIT_CODE_MODULES.md). The goal is to sequence the work so we reduce real risk quickly, unblock safe usage, and avoid spending time polishing modules that still have broken foundations.

## Planning Goals

- Fix real breakage before improving ergonomics
- Resolve security/protocol correctness before adding features
- Make optional dependencies safe at module boundaries
- Increase confidence in high-blast-radius modules first
- Avoid deep feature work in subsystems that still lack basic validation and tests

## Priority Order

### Phase 2: Security and Protocol Correctness

1. Tighten WebSocket handshake validation
   - Status: the originally identified handshake issues are now fixed and regression-tested
   - Client side:
     - verify `Upgrade: websocket`
     - verify `Connection: Upgrade`
   - Server side:
     - require `GET`
     - validate subprotocol negotiation against client-offered values
     - continue expanding tests for malformed or conflicting upgrade headers and negotiation edge cases

2. Enforce WebSocket frame rules
   - Status: the original masking/reserved-bit/control-frame issues are now fixed and regression-tested
   - Remaining work:
     - extend coverage for close-handshake behavior, fragmentation flows, ping/pong, and compression paths
     - verify close/error behavior for each protocol violation across both client and server roles

3. Review externally influenced filesystem and process boundaries in system modules
   - Focus next on:
     - `fs`
     - `os`
     - `vfs`
     - `stdio`
   - Goal: ensure unsafe inputs do not silently produce dangerous behavior

### Phase 3: Test the High-Blast-Radius Foundations

Once the boundaries are correct, raise confidence in the modules most other systems depend on.

1. Add dedicated tests for native/system wrappers
   - Priority order:
     - `fs`
     - `os`
     - `_socket`
     - `_ssl`
     - `sqlite3`
     - `regex`
     - `stdio`
     - `vfs`
     - `_fs_watch`
   - Why these first: failures here cascade into many higher-level modules

2. Strengthen WebSocket test coverage substantially
   - Current coverage is better, but still not broad enough
   - Add tests for:
     - client handshake acceptance/rejection
     - server upgrade validation
     - fragmentation
     - close handshake
     - ping/pong
     - compressed and uncompressed flows
     - invalid frames

3. Expand `ServerSession` tests
   - Add coverage for:
     - cookie rotation/regeneration
     - expiration
     - file store failure paths
     - sqlite store edge cases
   - Status: malicious-id and invalid-cookie regression coverage now exists

## Recommended Workstreams

To make this manageable, split the work into tracks rather than attacking modules one by one in isolation.

### Workstream C: Foundation Test Coverage

Focus:

- native/system wrappers
- regression tests for fixed bugs
- build-matrix confidence

Modules:

- `fs`
- `os`
- `_socket`
- `_ssl`
- `sqlite3`
- `stdio`
- `regex`
- `vfs`
- `_fs_watch`
