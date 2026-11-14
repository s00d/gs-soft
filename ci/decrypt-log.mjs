#!/usr/bin/env node
// Decrypts a build log written by ci/quiet.mjs (artifact build-log of a failed run).
//   gh run download <run-id> -R s00d/gs-soft -n build-log -D logs
//   node ci/decrypt-log.mjs logs/build-*.json ~/.gs-soft-ci/log-key.pem > build.log
import { constants, createDecipheriv, privateDecrypt } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const [file, keyPath = join(homedir(), ".gs-soft-ci", "log-key.pem")] = process.argv.slice(2);
if (!file) {
  console.error("usage: decrypt-log.mjs <build-*.json> [private-key.pem]");
  process.exit(2);
}
const box = JSON.parse(readFileSync(file, "utf8"));
const key = privateDecrypt(
  { key: readFileSync(keyPath, "utf8"), padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: "sha256" },
  Buffer.from(box.key, "base64"),
);
const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(box.iv, "base64"));
decipher.setAuthTag(Buffer.from(box.tag, "base64"));
process.stderr.write(`# ${box.command}\n`);
process.stdout.write(Buffer.concat([decipher.update(Buffer.from(box.data, "base64")), decipher.final()]));
