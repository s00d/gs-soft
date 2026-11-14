#!/usr/bin/env node
// Runs a build command with its output kept out of the log.
//
// This repository is public, so are its Actions logs, and compiler / bundler errors quote source
// lines of the private gateway-soft-rs. The command's stdout + stderr go to a file; on success only
// a one-line summary is printed, on failure the log is encrypted for the owner (AES-256-GCM, key
// sealed with RSA-OAEP to the LOG_PUBLIC_KEY secret) into $RUNNER_TEMP/build-logs/ for upload-artifact.
// Decrypt locally: node ci/decrypt-log.mjs <file> ~/.gs-soft-ci/log-key.pem
//
//   node ci/quiet.mjs pnpm tauri build --target x86_64-pc-windows-msvc
import { spawnSync } from "node:child_process";
import { constants, createCipheriv, publicEncrypt, randomBytes } from "node:crypto";
import { closeSync, mkdirSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [cmd, ...args] = process.argv.slice(2);
if (!cmd) {
  console.error("usage: quiet.mjs <command> [args...]");
  process.exit(2);
}

const temp = process.env.RUNNER_TEMP || process.cwd();
const stamp = `${Date.now()}-${process.pid}`;
const logPath = join(temp, `build-${stamp}.log`);
const fd = openSync(logPath, "w");
const started = Date.now();
const run = spawnSync(cmd, args, {
  stdio: ["ignore", fd, fd],
  env: process.env,
  // pnpm / npm are .cmd shims on Windows.
  shell: process.platform === "win32",
});
closeSync(fd);

const log = readFileSync(logPath);
rmSync(logPath, { force: true });
const lines = log.toString("utf8").split("\n").length;
const label = [cmd, ...args.slice(0, 2)].join(" ");
const secs = Math.round((Date.now() - started) / 1000);
const status = run.status ?? 1;

if (status === 0) {
  console.log(`ok: ${label} (${secs}s, ${lines} log lines hidden)`);
  process.exit(0);
}

const publicKey = process.env.LOG_PUBLIC_KEY;
if (!publicKey) {
  // Never print the log instead: it quotes source.
  console.log(`::error::${label} failed with exit ${status}; LOG_PUBLIC_KEY is not set, log dropped`);
  process.exit(status);
}
const key = randomBytes(32);
const iv = randomBytes(12);
const cipher = createCipheriv("aes-256-gcm", key, iv);
const data = Buffer.concat([cipher.update(log), cipher.final()]);
const sealed = publicEncrypt(
  { key: publicKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: "sha256" },
  key,
);
const outDir = join(temp, "build-logs");
mkdirSync(outDir, { recursive: true });
const outPath = join(outDir, `build-${stamp}.json`);
writeFileSync(
  outPath,
  JSON.stringify({
    v: 1,
    command: label,
    key: sealed.toString("base64"),
    iv: iv.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
    data: data.toString("base64"),
  }),
);
const why = run.error ? ` (${run.error.code ?? "spawn error"})` : "";
console.log(
  `::error::${label} failed with exit ${status}${why} after ${secs}s; ${lines} log lines encrypted into the build-log artifact`,
);
process.exit(status);
