// Redis ACL sync for the EVtivity CSMS Helm chart (pre-install and pre-upgrade
// hook). Runs in the migrate image (Node, with the ioredis package).
//
// A release can add a key prefix or channel to a service user
// (redis/acl-rules.conf). Redis keeps the users it already has, so without
// this job an upgraded install runs the new pods against the previous rules
// and their new keys fail with NOPERM. For each user of the rules file the job:
//
//   1. Replaces the user's keys, channels and commands with the rules file
//      (ACL SETUSER <user> resetkeys resetchannels nocommands clearselectors
//      <rules>). Passwords and the on/off state stay as they are.
//   2. Persists the change, so a Redis restart keeps it: it rewrites the
//      user's line in the Secret or ConfigMap the Redis loads its ACL file
//      from at start (the bundled Bitnami Redis), or runs ACL SAVE for a Redis
//      with a writable aclfile.
//
// Without the admin password (REDIS_ADMIN_PASSWORD unset: no bundled Redis,
// or an external Redis without redisAcl.admin) it changes nothing and exits 0:
// apply the rules by hand as the README describes. A failure stops the
// upgrade before any Deployment changes.

import { readFileSync } from 'node:fs';
import { request } from 'node:https';
import { createRequire } from 'node:module';

const require = createRequire(`${process.env.APP_ROOT || '/app'}/package.json`);

function log(message) {
  console.log(`[redis-acl-sync] ${message}`);
}

/** Parses acl-rules.conf: Map<user, rule tokens>. */
export function parseRules(text) {
  const users = new Map();
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) continue;
    const [keyword, name, ...rules] = line.split(/\s+/);
    if (keyword !== 'user' || !name) throw new Error(`unexpected line in acl-rules.conf: ${line}`);
    users.set(name, rules);
  }
  if (users.size === 0) throw new Error('acl-rules.conf lists no users');
  return users;
}

// Tokens of an ACL file line that are not permissions: state and passwords.
const isCredentialToken = (t) =>
  t === 'on' || t === 'off' || t === 'nopass' || t === 'resetpass' || /^[><#!]/.test(t);

/**
 * Rewrites the permissions of each user line of an ACL file to `rules`,
 * keeping its state and password tokens. Throws when a user has no line.
 */
export function setAclRules(text, rulesByUser) {
  const found = new Set();
  const lines = text.split('\n').map((line) => {
    const tokens = line.trim().split(/\s+/);
    const rules = tokens[0] === 'user' ? rulesByUser.get(tokens[1]) : undefined;
    if (rules === undefined) return line;
    found.add(tokens[1]);
    return ['user', tokens[1], ...tokens.slice(2).filter(isCredentialToken), ...rules].join(' ');
  });
  for (const user of rulesByUser.keys()) {
    if (!found.has(user)) throw new Error(`the Redis ACL file has no line for user ${user}`);
  }
  return lines.join('\n');
}

// --- Kubernetes API (in-cluster service account) ---

const SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount';

function kubeCall(method, path, body) {
  const data = body === undefined ? undefined : JSON.stringify(body);
  const token = readFileSync(`${SA_DIR}/token`, 'utf8').trim();
  return new Promise((resolve, reject) => {
    const req = request(
      {
        host: process.env.KUBERNETES_SERVICE_HOST,
        port: process.env.KUBERNETES_SERVICE_PORT || '443',
        method,
        path,
        ca: readFileSync(`${SA_DIR}/ca.crt`),
        timeout: 30_000,
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: 'application/json',
          ...(data !== undefined && {
            'Content-Type': 'application/merge-patch+json',
            'Content-Length': Buffer.byteLength(data),
          }),
        },
      },
      (res) => {
        let text = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          text += chunk;
        });
        res.on('end', () => {
          let parsed = {};
          if (text !== '') {
            try {
              parsed = JSON.parse(text);
            } catch (err) {
              parsed = { message: `${text.slice(0, 200)} (${err.message})` };
            }
          }
          resolve({ status: res.statusCode ?? 0, body: parsed });
        });
      },
    );
    req.on('timeout', () => req.destroy(new Error(`${method} ${path} timed out`)));
    req.on('error', reject);
    if (data !== undefined) req.write(data);
    req.end();
  });
}

function objectPath(kind, name) {
  const namespace = readFileSync(`${SA_DIR}/namespace`, 'utf8').trim();
  const plural = kind === 'Secret' ? 'secrets' : 'configmaps';
  return `/api/v1/namespaces/${namespace}/${plural}/${encodeURIComponent(name)}`;
}

/** The ACL source object and its text, or null when it does not exist or lacks the key. */
async function readAclSource({ kind, name, key }) {
  const res = await kubeCall('GET', objectPath(kind, name));
  if (res.status === 404) return null;
  if (res.status < 200 || res.status > 299) {
    throw new Error(`reading ${kind} ${name} failed: HTTP ${String(res.status)} ${res.body.message ?? ''}`);
  }
  const value = res.body.data?.[key];
  if (value == null) return null;
  const text = kind === 'Secret' ? Buffer.from(value, 'base64').toString('utf8') : value;
  return { kind, name, key, object: res.body, text };
}

async function writeAclSource(source, text) {
  const value = source.kind === 'Secret' ? Buffer.from(text, 'utf8').toString('base64') : text;
  // The resourceVersion makes the write conditional (409 when changed meanwhile).
  const res = await kubeCall('PATCH', objectPath(source.kind, source.name), {
    metadata: { resourceVersion: source.object.metadata.resourceVersion },
    data: { [source.key]: value },
  });
  if (res.status < 200 || res.status > 299) {
    throw new Error(
      `updating ${source.kind} ${source.name} failed: HTTP ${String(res.status)} ${res.body.message ?? ''}`,
    );
  }
}

/**
 * Where the Redis loads its ACL file from at start. An explicit
 * REDIS_ACL_NAME must exist. Otherwise the candidates of the bundled Bitnami
 * Redis are tried in order (REDIS_ACL_CANDIDATES, "Kind/name,..."); none found
 * returns null.
 */
async function findAclSource() {
  const key = process.env.REDIS_ACL_KEY || 'users.acl';
  if (process.env.REDIS_ACL_NAME) {
    const source = await readAclSource({
      kind: process.env.REDIS_ACL_KIND || 'Secret',
      name: process.env.REDIS_ACL_NAME,
      key,
    });
    if (source == null) {
      throw new Error(`redisAcl.aclFile ${process.env.REDIS_ACL_KIND} ${process.env.REDIS_ACL_NAME} has no key ${key}`);
    }
    return source;
  }
  for (const candidate of (process.env.REDIS_ACL_CANDIDATES || '').split(',').filter(Boolean)) {
    const [kind, name] = candidate.split('/');
    const source = await readAclSource({ kind, name, key });
    if (source != null) return source;
  }
  return null;
}

// --- Redis ---

async function redisConnect() {
  const Redis = require('ioredis');
  const host = process.env.REDIS_HOST;
  if (!host) throw new Error('no Redis host: set dependencies.redisHost');
  const ca = process.env.REDIS_TLS_CA_PEM;
  const client = new Redis({
    host,
    port: Number(process.env.REDIS_PORT || 6379),
    username: process.env.REDIS_ADMIN_USER || 'default',
    password: process.env.REDIS_ADMIN_PASSWORD,
    lazyConnect: true,
    enableOfflineQueue: false,
    maxRetriesPerRequest: 0,
    retryStrategy: () => null,
    connectTimeout: 10_000,
    ...(process.env.REDIS_TLS === 'true' && { tls: { servername: host, ...(ca && { ca: [ca] }) } }),
  });
  client.on('error', () => {});
  await client.connect();
  return client;
}

async function main() {
  if (!process.env.REDIS_ADMIN_PASSWORD) {
    log(
      'No Redis admin password (redisAcl.admin.passwordSecret): skipped. Apply redis/acl-rules.conf ' +
        'to the service users yourself (README, External Redis).',
    );
    return;
  }
  const rulesByUser = parseRules(readFileSync(process.env.RULES_FILE || '/opt/evtivity/acl-rules.conf', 'utf8'));
  const source = await findAclSource();
  const admin = await redisConnect();
  try {
    let aclFile = '';
    try {
      aclFile = (await admin.call('CONFIG', 'GET', 'aclfile'))[1] ?? '';
    } catch (err) {
      throw new Error(`the Redis admin user cannot run CONFIG GET (${err.message})`);
    }
    if (source == null && aclFile.startsWith('/opt/bitnami/')) {
      throw new Error(
        'Bitnami Redis rebuilds its ACL file from a Secret or ConfigMap at start, and none was found: set redisAcl.aclFile',
      );
    }
    // Check every user before anything changes.
    let text = source?.text;
    if (text !== undefined) text = setAclRules(text, rulesByUser);
    for (const user of rulesByUser.keys()) {
      if ((await admin.call('ACL', 'GETUSER', user)) == null) {
        throw new Error(`Redis user ${user} does not exist: create it first (README, Redis Access Control)`);
      }
    }
    for (const [user, rules] of rulesByUser) {
      await admin.call('ACL', 'SETUSER', user, 'resetkeys', 'resetchannels', 'nocommands', 'clearselectors', ...rules);
      log(`applied the rules of ${user}`);
    }
    if (source != null) {
      if (text !== source.text) await writeAclSource(source, text);
      log(`persisted in ${source.kind} ${source.name}`);
    } else if (aclFile !== '') {
      await admin.call('ACL', 'SAVE');
      log(`persisted with ACL SAVE (${aclFile})`);
    } else {
      try {
        await admin.call('CONFIG', 'REWRITE');
      } catch (err) {
        throw new Error(
          `the rules are applied but a Redis restart would lose them: Redis has no aclfile and CONFIG REWRITE failed (${err.message}). ` +
            'Persist them yourself, or set redisAcl.aclFile',
        );
      }
      log('persisted with CONFIG REWRITE');
    }
  } finally {
    admin.disconnect();
  }
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  main().catch((err) => {
    console.error(`[redis-acl-sync] failed: ${err.message}`);
    process.exit(1);
  });
}
