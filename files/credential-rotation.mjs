// Credential rotation for the EVtivity CSMS Helm chart.
//
// Runs in the migrate image (Node, with the postgres and ioredis packages).
//
// MODE=init   (pre-install and pre-upgrade hook): creates the credentials
//             Secret from the chart values when it does not exist, and adds
//             the keys of newly enabled services. Never overwrites a key.
// MODE=rotate (CronJob): rotates the PostgreSQL application login, the
//             PostgreSQL owner password and the Redis ACL user passwords.
//
// Rotation order, so running pods never lose a working credential:
//   1. Preflight every connection and server setting. Nothing changes on failure.
//   2. Set the new credentials next to the old ones: the idle PostgreSQL login
//      of the alternating pair gets a new password, each Redis user gets a
//      second password.
//   3. Write the new credentials to the Secret and restart the deployments.
//   4. After every rollout completes and the grace delay passes, remove the old
//      credentials: the previous PostgreSQL login loses its password, each
//      Redis user keeps only the new password.
//   5. Rotate the owner password (used only by the migrate and seed jobs).
// A run that fails before step 4 leaves the old credentials valid. The next run
// finishes an unfinished rollout before it rotates again.

import { readFileSync } from 'node:fs';
import { request } from 'node:https';
import { createHash, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';
import { setTimeout as sleep } from 'node:timers/promises';

const require = createRequire(`${process.env.APP_ROOT || '/app'}/package.json`);

const PHASE = 'evtivity.com/rotation-phase';
const ROTATED_AT = 'evtivity.com/rotated-at';
const PENDING_ROLLOUT = 'pending-rollout';
const ROLLED_OUT = 'rolled-out';
const OWNER_PENDING_KEY = 'MIGRATE_DATABASE_URL_PENDING';

function log(message) {
  console.log(`[rotation] ${message}`);
}

function env(name) {
  const value = process.env[name];
  if (value == null || value === '') throw new Error(`${name} is not set`);
  return value;
}

function flag(name) {
  return process.env[name] === 'true';
}

function newPassword() {
  // 256 bits, URL-safe: no encoding issues in connection URLs or ACL files.
  return randomBytes(32).toString('base64url');
}

// --- Kubernetes API (in-cluster service account) ---

const SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount';
const kube = {
  host: env('KUBERNETES_SERVICE_HOST'),
  port: process.env.KUBERNETES_SERVICE_PORT || '443',
  namespace: readFileSync(`${SA_DIR}/namespace`, 'utf8').trim(),
  ca: readFileSync(`${SA_DIR}/ca.crt`),
};

function kubeCall(method, path, body, contentType = 'application/json') {
  const data = body === undefined ? undefined : JSON.stringify(body);
  // The projected token is refreshed on disk, so read it for every call.
  const token = readFileSync(`${SA_DIR}/token`, 'utf8').trim();
  return new Promise((resolve, reject) => {
    const req = request(
      {
        host: kube.host,
        port: kube.port,
        method,
        path,
        ca: kube.ca,
        timeout: 30_000,
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: 'application/json',
          ...(data !== undefined && {
            'Content-Type': contentType,
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
            } catch {
              parsed = { message: text.slice(0, 200) };
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

function expectOk(res, what) {
  if (res.status < 200 || res.status > 299) {
    throw new Error(`${what} failed: HTTP ${String(res.status)} ${res.body.message ?? ''}`);
  }
  return res.body;
}

const secretsPath = () => `/api/v1/namespaces/${kube.namespace}/secrets`;
const secretPath = (name) => `${secretsPath()}/${encodeURIComponent(name)}`;
const deploymentPath = (name) =>
  `/apis/apps/v1/namespaces/${kube.namespace}/deployments/${encodeURIComponent(name)}`;

async function readSecret(name) {
  const res = await kubeCall('GET', secretPath(name));
  if (res.status === 404) return null;
  return expectOk(res, `reading Secret ${name}`);
}

function secretValue(secret, key) {
  const value = secret.data?.[key];
  return value == null ? undefined : Buffer.from(value, 'base64').toString('utf8');
}

const b64 = (value) => Buffer.from(value, 'utf8').toString('base64');

/**
 * Merge-patches a Secret. The resourceVersion makes the write conditional: a
 * Secret changed by someone else since it was read fails with 409.
 */
async function patchSecret(secret, { set = {}, remove = [], annotations = {} }) {
  const data = {};
  for (const [key, value] of Object.entries(set)) data[key] = b64(value);
  for (const key of remove) data[key] = null;
  const res = await kubeCall(
    'PATCH',
    secretPath(secret.metadata.name),
    { metadata: { resourceVersion: secret.metadata.resourceVersion, annotations }, data },
    'application/merge-patch+json',
  );
  return expectOk(res, `updating Secret ${secret.metadata.name}`);
}

async function restartDeployments(names) {
  const stamp = new Date().toISOString();
  for (const name of names) {
    const res = await kubeCall(
      'PATCH',
      deploymentPath(name),
      { spec: { template: { metadata: { annotations: { 'kubectl.kubernetes.io/restartedAt': stamp } } } } },
      'application/strategic-merge-patch+json',
    );
    expectOk(res, `restarting Deployment ${name}`);
    log(`restarted ${name}`);
  }
}

/** Same completion test as `kubectl rollout status`. */
async function waitForRollouts(names, timeoutSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  for (const name of names) {
    for (;;) {
      const d = expectOk(await kubeCall('GET', deploymentPath(name)), `reading Deployment ${name}`);
      const s = d.status ?? {};
      const want = d.spec?.replicas ?? 1;
      const stalled = (s.conditions ?? []).some(
        (c) => c.type === 'Progressing' && c.reason === 'ProgressDeadlineExceeded',
      );
      if (stalled) throw new Error(`Deployment ${name} exceeded its progress deadline`);
      const done =
        (s.observedGeneration ?? 0) >= (d.metadata?.generation ?? 0) &&
        (s.updatedReplicas ?? 0) >= want &&
        (s.replicas ?? 0) <= (s.updatedReplicas ?? 0) &&
        (s.availableReplicas ?? 0) >= want;
      if (done) break;
      if (Date.now() > deadline) {
        throw new Error(`Deployment ${name} did not finish its rollout within ${String(timeoutSeconds)}s`);
      }
      await sleep(5_000);
    }
    log(`rollout of ${name} complete`);
  }
}

// --- Configuration ---

const COMPONENTS = (process.env.COMPONENTS ?? '').split(',').filter((c) => c !== '');
const redisKey = (component) => `REDIS_URL_${component.toUpperCase()}`;

// --- init mode ---

async function init() {
  const name = env('CREDENTIALS_SECRET');
  const seed = { DATABASE_URL: env('SEED_DATABASE_URL') };
  seed.MIGRATE_DATABASE_URL = seed.DATABASE_URL;
  for (const component of COMPONENTS) {
    seed[redisKey(component)] = env(`SEED_${redisKey(component)}`);
  }

  let secret = await readSecret(name);
  if (secret == null) {
    const labels = JSON.parse(process.env.SECRET_LABELS || '{}');
    const data = {};
    for (const [key, value] of Object.entries(seed)) data[key] = b64(value);
    const res = await kubeCall('POST', secretsPath(), {
      apiVersion: 'v1',
      kind: 'Secret',
      type: 'Opaque',
      metadata: { name, labels, annotations: { [PHASE]: ROLLED_OUT } },
      data,
    });
    if (res.status !== 409) {
      expectOk(res, `creating Secret ${name}`);
      log(`created ${name} from the chart values`);
      return;
    }
    secret = await readSecret(name);
    if (secret == null) throw new Error(`Secret ${name} conflicted on create but cannot be read`);
  }
  const missing = {};
  for (const [key, value] of Object.entries(seed)) {
    if (secretValue(secret, key) === undefined) missing[key] = value;
  }
  if (Object.keys(missing).length === 0) {
    log(`kept ${name}: it holds the current credentials`);
    return;
  }
  await patchSecret(secret, { set: missing });
  log(`added ${Object.keys(missing).join(', ')} to ${name}`);
}

// --- PostgreSQL ---

/** SCRAM-SHA-256 verifier, so the plain password never reaches the server or its logs. */
function scramVerifier(password) {
  const iterations = 4096;
  const salt = randomBytes(16);
  const salted = pbkdf2Sync(password.normalize('NFKC'), salt, iterations, 32, 'sha256');
  const clientKey = createHmac('sha256', salted).update('Client Key').digest();
  const storedKey = createHash('sha256').update(clientKey).digest();
  const serverKey = createHmac('sha256', salted).update('Server Key').digest();
  return `SCRAM-SHA-256$${String(iterations)}:${salt.toString('base64')}$${storedKey.toString('base64')}:${serverKey.toString('base64')}`;
}

function urlUser(url) {
  return decodeURIComponent(new URL(url).username);
}

function withCredentials(url, user, password) {
  const u = new URL(url);
  u.username = encodeURIComponent(user);
  u.password = encodeURIComponent(password);
  return u.toString();
}

function pgConnect(url) {
  const postgres = require('postgres');
  return postgres(url, { max: 1, connect_timeout: 10, idle_timeout: 5, onnotice: () => {} });
}

async function pgCanLogin(url, probeTable) {
  const sql = pgConnect(url);
  try {
    if (probeTable) await sql.unsafe(`SELECT 1 FROM ${probeTable} LIMIT 1`);
    else await sql`SELECT 1`;
    return true;
  } catch (err) {
    log(`login check as ${urlUser(url)} failed: ${err.message}`);
    return false;
  } finally {
    await sql.end({ timeout: 5 });
  }
}

/** Runs a statement built with server-side format(): %I quotes identifiers, %L literals. */
async function pgRun(sql, fmt, ...args) {
  const params = args.map((a) => String(a));
  const placeholders = params.map((_, i) => `$${String(i + 2)}::text`).join(', ');
  const [row] = await sql.unsafe(`SELECT format($1::text${placeholders ? `, ${placeholders}` : ''}) AS stmt`, [
    fmt,
    ...params,
  ]);
  await sql.unsafe(row.stmt);
}

async function roleExists(sql, name) {
  const [row] = await sql.unsafe('SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1) AS present', [name]);
  return row.present;
}

function database() {
  const appUser = env('DB_APP_USER');
  return {
    appUser,
    cloneUser: `${appUser}_clone`,
    group: env('DB_GROUP_ROLE'),
    adminUser: env('PG_ADMIN_USER'),
    adminPassword: env('PG_ADMIN_PASSWORD'),
  };
}

function adminUrl(db, ownerUrl) {
  return withCredentials(ownerUrl, db.adminUser, db.adminPassword);
}

/** Group role with the application privileges, the same grants the CDK database job applies. */
async function bootstrapGroup(sql, db, owner, dbName) {
  if (!(await roleExists(sql, db.group))) await pgRun(sql, 'CREATE ROLE %I NOLOGIN', db.group);
  await pgRun(sql, 'GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', dbName, db.group);
  await pgRun(sql, 'GRANT USAGE ON SCHEMA public TO %I', db.group);
  await pgRun(sql, 'GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public TO %I', db.group);
  await pgRun(sql, 'GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO %I', db.group);
  await pgRun(sql, 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO %I', db.group);
  await pgRun(sql, 'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO %I', owner, db.group);
  await pgRun(sql, 'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', owner, db.group);
  await pgRun(sql, 'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO %I', owner, db.group);
  await pgRun(sql, 'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT USAGE ON TYPES TO %I', owner, db.group);
}

async function pgPreflight(db, secret) {
  const ownerUrl = secretValue(secret, 'MIGRATE_DATABASE_URL');
  const appUrl = secretValue(secret, 'DATABASE_URL');
  if (!ownerUrl || !appUrl) throw new Error('the credentials Secret has no DATABASE_URL or MIGRATE_DATABASE_URL');
  const owner = urlUser(ownerUrl);
  if ([db.appUser, db.cloneUser, db.group].includes(owner)) {
    throw new Error(`credentialRotation.database.appUser must differ from the owner role ${owner}`);
  }
  const sql = pgConnect(adminUrl(db, ownerUrl));
  try {
    const [row] = await sql.unsafe(
      'SELECT rolsuper OR rolcreaterole AS can FROM pg_roles WHERE rolname = current_user',
    );
    if (!row?.can) throw new Error(`PostgreSQL admin ${db.adminUser} needs SUPERUSER or CREATEROLE`);
  } finally {
    await sql.end({ timeout: 5 });
  }
  if (!(await pgCanLogin(ownerUrl))) throw new Error('the owner credential (MIGRATE_DATABASE_URL) does not log in');
  if (!(await pgCanLogin(appUrl))) throw new Error('the application credential (DATABASE_URL) does not log in');
}

/** Gives the idle login of the alternating pair a new password. Returns the new DATABASE_URL. */
async function pgStageAppLogin(db, secret) {
  const ownerUrl = secretValue(secret, 'MIGRATE_DATABASE_URL');
  const appUrl = secretValue(secret, 'DATABASE_URL');
  const owner = urlUser(ownerUrl);
  const current = urlUser(appUrl);
  const next = current === db.appUser ? db.cloneUser : db.appUser;
  const dbName = decodeURIComponent(new URL(ownerUrl).pathname.slice(1));
  const password = newPassword();
  const sql = pgConnect(adminUrl(db, ownerUrl));
  try {
    await bootstrapGroup(sql, db, owner, dbName);
    if (await roleExists(sql, next)) {
      await pgRun(sql, 'ALTER ROLE %I WITH LOGIN PASSWORD %L', next, scramVerifier(password));
    } else {
      await pgRun(sql, 'CREATE ROLE %I WITH LOGIN PASSWORD %L', next, scramVerifier(password));
    }
    await pgRun(sql, 'GRANT %I TO %I', db.group, next);
    // Privileges arrive through the group role, so the login inherits them.
    await pgRun(sql, 'ALTER ROLE %I INHERIT', next);
  } finally {
    await sql.end({ timeout: 5 });
  }
  const nextUrl = withCredentials(appUrl, next, password);
  // Reads a migrated table, so a missing grant fails here and not in the pods.
  if (!(await pgCanLogin(nextUrl, 'settings'))) {
    throw new Error(`the new login ${next} cannot read the settings table`);
  }
  log(`database login ${next} has a new password (pods use ${current} until they restart)`);
  return nextUrl;
}

/** Removes the password of the alternating login the pods no longer use. */
async function pgRevokePrevious(db, secret) {
  const ownerUrl = secretValue(secret, 'MIGRATE_DATABASE_URL');
  const current = urlUser(secretValue(secret, 'DATABASE_URL'));
  const owner = urlUser(ownerUrl);
  const sql = pgConnect(adminUrl(db, ownerUrl));
  try {
    for (const role of [db.appUser, db.cloneUser]) {
      if (role === current || role === owner || !(await roleExists(sql, role))) continue;
      await pgRun(sql, 'ALTER ROLE %I WITH PASSWORD NULL', role);
      log(`database login ${role} no longer has a password`);
    }
  } finally {
    await sql.end({ timeout: 5 });
  }
}

/** Settles an owner rotation that stopped between the password change and the Secret update. */
async function pgResolveOwnerPending(name) {
  const secret = await readSecret(name);
  const pending = secretValue(secret, OWNER_PENDING_KEY);
  if (pending === undefined) return;
  if (await pgCanLogin(pending)) {
    await patchSecret(secret, { set: { MIGRATE_DATABASE_URL: pending }, remove: [OWNER_PENDING_KEY] });
    log('kept the owner password of an unfinished rotation');
  } else {
    await patchSecret(secret, { remove: [OWNER_PENDING_KEY] });
    log('dropped the owner password of an unfinished rotation (never applied)');
  }
}

/** Single-user rotation of the owner: only the migrate and seed jobs use it. */
async function pgRotateOwner(db, name) {
  let secret = await readSecret(name);
  const ownerUrl = secretValue(secret, 'MIGRATE_DATABASE_URL');
  const owner = urlUser(ownerUrl);
  if (urlUser(secretValue(secret, 'DATABASE_URL')) === owner) {
    log('owner password kept: the pods still log in as the owner');
    return;
  }
  const nextUrl = withCredentials(ownerUrl, owner, newPassword());
  // Written first, so a stop after ALTER ROLE never loses the owner password.
  secret = await patchSecret(secret, { set: { [OWNER_PENDING_KEY]: nextUrl } });
  const sql = pgConnect(adminUrl(db, ownerUrl));
  try {
    await pgRun(sql, 'ALTER ROLE %I WITH PASSWORD %L', owner, scramVerifier(decodeURIComponent(new URL(nextUrl).password)));
  } finally {
    await sql.end({ timeout: 5 });
  }
  if (!(await pgCanLogin(nextUrl))) throw new Error(`the new owner password of ${owner} does not log in`);
  await patchSecret(secret, { set: { MIGRATE_DATABASE_URL: nextUrl }, remove: [OWNER_PENDING_KEY] });
  log(`owner ${owner} has a new password`);
}

// --- Redis ---

function redisTarget(url) {
  const u = new URL(url);
  return {
    tls: u.protocol === 'rediss:',
    host: u.hostname.replace(/^\[|\]$/g, ''),
    port: Number(u.port || 6379),
    user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
  };
}

async function redisConnect(target, user, password) {
  const Redis = require('ioredis');
  const ca = process.env.REDIS_TLS_CA_PEM;
  const client = new Redis({
    host: target.host,
    port: target.port,
    username: user,
    password,
    lazyConnect: true,
    enableOfflineQueue: false,
    maxRetriesPerRequest: 0,
    retryStrategy: () => null,
    connectTimeout: 10_000,
    ...(target.tls && { tls: { servername: target.host, ...(ca && { ca: [ca] }) } }),
  });
  client.on('error', () => {});
  await client.connect();
  return client;
}

async function redisCanLogin(target, user, password) {
  try {
    const client = await redisConnect(target, user, password);
    await client.ping();
    client.disconnect();
    return true;
  } catch (err) {
    log(`Redis login check as ${user} failed: ${err.message}`);
    return false;
  }
}

/** One entry per Redis user, with the Secret keys that hold its URL. */
function redisUsers(secret) {
  const users = new Map();
  let server;
  for (const component of COMPONENTS) {
    const url = secretValue(secret, redisKey(component));
    if (!url) throw new Error(`the credentials Secret has no ${redisKey(component)}`);
    const t = redisTarget(url);
    const where = `${t.host}:${String(t.port)}`;
    if (server && server !== where) throw new Error('every Redis URL must point at the same server');
    server = where;
    if (!t.user || t.user === 'default') {
      throw new Error(`${redisKey(component)} must use its own ACL user, not the default user`);
    }
    const entry = users.get(t.user) ?? { target: t, keys: [] };
    entry.keys.push(redisKey(component));
    users.set(t.user, entry);
  }
  return users;
}

function redisAdmin(users) {
  const [first] = users.values();
  return redisConnect(first.target, env('REDIS_ADMIN_USER'), env('REDIS_ADMIN_PASSWORD'));
}

/** Rewrites the password tokens (>plain, #hash) of one user line of an ACL file. */
function setAclPasswords(text, user, passwords) {
  let found = false;
  const lines = text.split('\n').map((line) => {
    const tokens = line.trim().split(/\s+/);
    if (tokens[0] !== 'user' || tokens[1] !== user) return line;
    found = true;
    const rules = tokens
      .slice(2)
      .filter((t) => !/^[><#!]/.test(t) && t !== 'nopass' && t !== 'resetpass');
    // SHA-256 hashes (#<hex>), so the file holds no plain password.
    const hashes = passwords.map((p) => `#${createHash('sha256').update(p).digest('hex')}`);
    return ['user', user, ...hashes, ...rules].join(' ');
  });
  if (!found) throw new Error(`the Redis ACL file has no line for user ${user}`);
  return lines.join('\n');
}

// The Kubernetes object Redis loads its ACL file from at start (REDIS_ACL_NAME):
// a Secret (Bitnami Redis chart 27 and later) or a ConfigMap (earlier charts).
const aclSource = () => ({
  kind: process.env.REDIS_ACL_KIND || 'Secret',
  name: process.env.REDIS_ACL_NAME,
  key: process.env.REDIS_ACL_KEY || 'users.acl',
});

async function readAclSource() {
  const { kind, name, key } = aclSource();
  let object;
  let text;
  if (kind === 'Secret') {
    object = await readSecret(name);
    text = object == null ? undefined : secretValue(object, key);
  } else if (kind === 'ConfigMap') {
    const res = await kubeCall('GET', `/api/v1/namespaces/${kube.namespace}/configmaps/${encodeURIComponent(name)}`);
    object = res.status === 404 ? null : expectOk(res, `reading ConfigMap ${name}`);
    text = object?.data?.[key];
  } else {
    throw new Error(`credentialRotation.redis.aclFile.kind must be Secret or ConfigMap, not ${kind}`);
  }
  if (object == null) throw new Error(`Redis ACL ${kind} ${name} does not exist`);
  if (text === undefined) throw new Error(`Redis ACL ${kind} ${name} has no key ${key}`);
  return { object, text };
}

async function updateAclSource(passwordsByUser) {
  if (!aclSource().name) return;
  const { kind, name, key } = aclSource();
  const { object, text: original } = await readAclSource();
  let text = original;
  for (const [user, passwords] of passwordsByUser) text = setAclPasswords(text, user, passwords);
  if (kind === 'Secret') {
    await patchSecret(object, { set: { [key]: text } });
    return;
  }
  const res = await kubeCall(
    'PATCH',
    `/api/v1/namespaces/${kube.namespace}/configmaps/${encodeURIComponent(name)}`,
    { metadata: { resourceVersion: object.metadata.resourceVersion }, data: { [key]: text } },
    'application/merge-patch+json',
  );
  expectOk(res, `updating ConfigMap ${name}`);
}

async function redisPreflight(secret) {
  const users = redisUsers(secret);
  const admin = await redisAdmin(users);
  try {
    const replication = await admin.info('replication');
    const replicas = Number(/connected_slaves:(\d+)/.exec(replication)?.[1] ?? '0');
    if (!/role:master/.test(replication) || replicas > 0) {
      throw new Error('Redis must be a single primary without replicas: ACL changes do not replicate');
    }
    let aclFile = '';
    try {
      aclFile = (await admin.call('CONFIG', 'GET', 'aclfile'))[1] ?? '';
    } catch (err) {
      throw new Error(`the Redis admin user cannot run CONFIG GET (${err.message})`);
    }
    if (aclSource().name) {
      // Every user line must exist before anything changes.
      const { text } = await readAclSource();
      for (const user of users.keys()) setAclPasswords(text, user, ['check']);
    } else if (aclFile === '') {
      throw new Error('Redis has no ACL file, so rotated passwords would be lost on restart');
    } else if (aclFile.startsWith('/opt/bitnami/')) {
      throw new Error(
        'Bitnami Redis rebuilds its ACL file from a Secret or ConfigMap at start: set credentialRotation.redis.aclFile',
      );
    }
    for (const [user, entry] of users) {
      const exists = await admin.call('ACL', 'GETUSER', user);
      if (exists == null) throw new Error(`Redis user ${user} does not exist`);
      if (!(await redisCanLogin(entry.target, user, entry.target.password))) {
        throw new Error(`the current Redis credential of ${user} does not log in`);
      }
    }
    return { aclFile };
  } finally {
    admin.disconnect();
  }
}

/** Saves the ACL file. With an ACL source object, that object is what survives a restart. */
async function redisPersist(admin, aclFile) {
  if (aclFile !== '' && !aclSource().name) await admin.call('ACL', 'SAVE');
}

/** Adds a second password to each user. Returns the Secret keys with their new URLs. */
async function redisStage(secret, aclFile) {
  const users = redisUsers(secret);
  const fresh = new Map();
  for (const user of users.keys()) fresh.set(user, newPassword());
  // The ACL source first holds both passwords, so a Redis restart at any point
  // still accepts the credential the pods use.
  await updateAclSource(
    new Map([...users].map(([user, entry]) => [user, [entry.target.password, fresh.get(user)]])),
  );
  const admin = await redisAdmin(users);
  const set = {};
  try {
    for (const [user, entry] of users) {
      await admin.call('ACL', 'SETUSER', user, `>${fresh.get(user)}`);
      for (const key of entry.keys) {
        set[key] = withCredentials(secretValue(secret, key), user, fresh.get(user));
      }
    }
    await redisPersist(admin, aclFile);
  } finally {
    admin.disconnect();
  }
  for (const [user, entry] of users) {
    if (!(await redisCanLogin(entry.target, user, fresh.get(user)))) {
      throw new Error(`the new Redis password of ${user} does not log in`);
    }
    log(`Redis user ${user} has a second password (pods use the first until they restart)`);
  }
  return set;
}

/** Leaves each user only the password in the Secret, which also drops any stray one. */
async function redisRevoke(secret, aclFile) {
  const users = redisUsers(secret);
  const admin = await redisAdmin(users);
  try {
    for (const [user, entry] of users) {
      await admin.call('ACL', 'SETUSER', user, 'resetpass', `>${entry.target.password}`);
      log(`Redis user ${user} keeps only the new password`);
    }
    await redisPersist(admin, aclFile);
  } finally {
    admin.disconnect();
  }
  await updateAclSource(new Map([...users].map(([user, entry]) => [user, [entry.target.password]])));
}

// --- rotate mode ---

async function rotate() {
  const name = env('CREDENTIALS_SECRET');
  const deployments = (process.env.DEPLOYMENTS ?? '').split(',').filter((d) => d !== '');
  const rotateDb = flag('ROTATE_DATABASE');
  const rotateOwner = rotateDb && flag('ROTATE_OWNER');
  const rotateRedis = flag('ROTATE_REDIS') && COMPONENTS.length > 0;
  const rolloutTimeout = Number(env('ROLLOUT_TIMEOUT_SECONDS'));
  const revokeDelay = Number(env('REVOKE_DELAY_SECONDS'));
  const db = rotateDb ? database() : undefined;

  if ((await readSecret(name)) == null) {
    throw new Error(`Secret ${name} does not exist: run helm upgrade with credentialRotation.enabled first`);
  }
  if (rotateOwner) await pgResolveOwnerPending(name);

  let secret = await readSecret(name);
  const preflightSecret = secret;
  if (rotateDb) await pgPreflight(db, preflightSecret);
  const { aclFile } = rotateRedis ? await redisPreflight(preflightSecret) : { aclFile: '' };

  const revoke = async () => {
    log(`waiting ${String(revokeDelay)}s for terminating pods to close their connections`);
    await sleep(revokeDelay * 1000);
    const current = await readSecret(name);
    if (rotateDb) await pgRevokePrevious(db, current);
    if (rotateRedis) await redisRevoke(current, aclFile);
    await patchSecret(current, { annotations: { [PHASE]: ROLLED_OUT } });
  };

  if (secret.metadata.annotations?.[PHASE] === PENDING_ROLLOUT) {
    log('finishing the rollout of the previous run');
    await restartDeployments(deployments);
    await waitForRollouts(deployments, rolloutTimeout);
    await revoke();
    secret = await readSecret(name);
  }

  const set = {};
  if (rotateDb) set.DATABASE_URL = await pgStageAppLogin(db, secret);
  if (rotateRedis) Object.assign(set, await redisStage(secret, aclFile));
  if (Object.keys(set).length > 0) {
    await patchSecret(secret, {
      set,
      annotations: { [PHASE]: PENDING_ROLLOUT, [ROTATED_AT]: new Date().toISOString() },
    });
    log(`wrote ${Object.keys(set).join(', ')} to ${name}`);
    await restartDeployments(deployments);
    await waitForRollouts(deployments, rolloutTimeout);
    await revoke();
  }
  if (rotateOwner) await pgRotateOwner(db, name);
  log('done');
}

const mode = env('MODE');
try {
  if (mode === 'init') await init();
  else if (mode === 'rotate') await rotate();
  else throw new Error(`unknown MODE ${mode}`);
} catch (err) {
  console.error(`[rotation] failed: ${err.message}`);
  process.exitCode = 1;
}
