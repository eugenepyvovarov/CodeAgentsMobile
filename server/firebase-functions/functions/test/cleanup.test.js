/* eslint-disable @typescript-eslint/no-var-requires */
const assert = require("node:assert/strict");
const test = require("node:test");

const {cleanupStalePushData} = require("../lib/cleanup.js");

function makeTimestamp(ms) {
  return {
    toMillis: () => ms,
  };
}

/**
 * Minimal in-memory Firestore stand-in for cleanup unit tests.
 */
function createFakeFirestore(seed) {
  // seed: { servers: { id: { data, agents: { id: { data, devices: { id: data } } } } } }
  // JSON clone only — timestamps are plain { toMillis } objects reattached by the test.
  const state = JSON.parse(JSON.stringify(seed, (_key, value) => {
    if (value && typeof value === "object" && typeof value.toMillis === "function") {
      return {__ms: value.toMillis()};
    }
    return value;
  }));
  // Revive timestamp markers.
  const revive = (node) => {
    if (!node || typeof node !== "object") {
      return;
    }
    for (const [k, v] of Object.entries(node)) {
      if (v && typeof v === "object" && typeof v.__ms === "number") {
        node[k] = {toMillis: () => v.__ms};
      } else {
        revive(v);
      }
    }
  };
  revive(state);

  function collection(name) {
    if (name !== "servers") {
      throw new Error(`unexpected root collection ${name}`);
    }
    return {
      limit() {
        return this;
      },
      async get() {
        const docs = Object.entries(state.servers || {}).map(([id, server]) => ({
          id,
          data: () => server.data || {},
          ref: serverRef(id),
        }));
        return {docs, size: docs.length};
      },
    };
  }

  function serverRef(serverId) {
    return {
      collection(name) {
        assert.equal(name, "agents");
        return {
          limit() {
            return this;
          },
          async get() {
            const agents = state.servers[serverId]?.agents || {};
            const docs = Object.entries(agents).map(([id, agent]) => ({
              id,
              data: () => agent.data || {},
              ref: agentRef(serverId, id),
            }));
            return {docs, size: docs.length};
          },
        };
      },
      async delete() {
        delete state.servers[serverId];
      },
    };
  }

  function agentRef(serverId, agentId) {
    return {
      collection(name) {
        assert.equal(name, "devices");
        return {
          limit() {
            return this;
          },
          async get() {
            const devices = state.servers[serverId]?.agents?.[agentId]?.devices || {};
            const docs = Object.entries(devices).map(([id, data]) => ({
              id,
              data: () => data || {},
              ref: deviceRef(serverId, agentId, id),
            }));
            return {docs, size: docs.length};
          },
        };
      },
      async delete() {
        delete state.servers[serverId].agents[agentId];
      },
    };
  }

  function deviceRef(serverId, agentId, deviceId) {
    return {
      async delete() {
        delete state.servers[serverId].agents[agentId].devices[deviceId];
      },
    };
  }

  return {
    collection,
    batch() {
      const ops = [];
      return {
        delete(ref) {
          ops.push(ref);
        },
        async commit() {
          for (const ref of ops) {
            await ref.delete();
          }
        },
      };
    },
    _state: state,
  };
}

test("cleanupStalePushData removes old devices, empty agents, empty servers", async () => {
  const now = Date.UTC(2026, 6, 10);
  const old = now - 100 * 24 * 60 * 60 * 1000;
  const fresh = now - 1 * 24 * 60 * 60 * 1000;

  const db = createFakeFirestore({
    servers: {
      staleServer: {
        data: {lastSeenAt: makeTimestamp(old)},
        agents: {
          staleAgent: {
            data: {updatedAt: makeTimestamp(old)},
            devices: {
              d1: {updatedAt: makeTimestamp(old), fcmToken: "t1"},
            },
          },
        },
      },
      liveServer: {
        data: {lastSeenAt: makeTimestamp(fresh)},
        agents: {
          liveAgent: {
            data: {updatedAt: makeTimestamp(fresh)},
            devices: {
              d2: {updatedAt: makeTimestamp(fresh), fcmToken: "t2"},
            },
          },
        },
      },
    },
  });

  const stats = await cleanupStalePushData(db, {
    nowMs: now,
    ttlMs: 90 * 24 * 60 * 60 * 1000,
  });

  assert.equal(stats.devicesDeleted, 1);
  assert.equal(stats.agentsDeleted, 1);
  assert.equal(stats.serversDeleted, 1);
  assert.equal(Boolean(db._state.servers.staleServer), false);
  assert.equal(Boolean(db._state.servers.liveServer), true);
  assert.equal(Boolean(db._state.servers.liveServer.agents.liveAgent.devices.d2), true);
});
