#!/usr/bin/env node
// Produce a reproducible provenance inventory while the source tree still exists.
// This is evidence for a license review, not a license-compliance determination.
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, realpathSync } from "node:fs";
import path from "node:path";

const [metadataPath, sourcePath, bundlePath] = process.argv.slice(2);
if (!metadataPath || !sourcePath || !bundlePath || process.argv.length !== 5) {
  throw new Error("Usage: node inventory-bundle.mjs <esbuild-metafile> <source-root> <server.mjs>");
}
const root = realpathSync(sourcePath);
const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
const insideRoot = (candidate) => candidate === root || candidate.startsWith(root + path.sep);
const packages = new Map();
const inputs = [];
const unresolved = [];

for (const [input, details] of Object.entries(metadata.inputs ?? {}).sort(([a], [b]) => a.localeCompare(b))) {
  let absolute;
  try { absolute = realpathSync(path.resolve(root, input)); }
  catch {
    unresolved.push({ input: path.isAbsolute(input) || input.startsWith("../") ? "[outside source root]" : input, reason: "source not found" });
    continue;
  }
  if (!insideRoot(absolute)) {
    unresolved.push({ input: "[outside source root]", reason: "source resolves outside source root" });
    continue;
  }
  let directory = path.dirname(absolute);
  let owner;
  while (insideRoot(directory)) {
    try {
      const manifest = JSON.parse(readFileSync(path.join(directory, "package.json"), "utf8"));
      if (typeof manifest.name === "string") {
        const packagePath = path.relative(root, directory) || ".";
        owner = packagePath;
        if (!packages.has(packagePath)) {
          const notices = readdirSync(directory).filter((name) => /^(?:third[-_ ]?party[-_ ]?)?(?:license|licence|copying|notice|unlicense)/i.test(name)).sort();
          packages.set(packagePath, {
            path: packagePath,
            name: manifest.name,
            version: manifest.version ?? null,
            declared_license: manifest.license ?? null,
            license_notice_files: notices,
          });
        }
        break;
      }
    } catch (error) {
      if (error.code !== "ENOENT") {
        unresolved.push({ input: path.relative(root, absolute), reason: "package metadata unreadable or invalid" });
        break;
      }
    }
    if (directory === root) break;
    directory = path.dirname(directory);
  }
  if (!owner) unresolved.push({ input: path.relative(root, absolute), reason: "no owning package metadata" });
  inputs.push({ path: path.relative(root, absolute), bytes: details.bytes, package_path: owner ?? null });
}

const externals = [...new Set(Object.values(metadata.outputs ?? {}).flatMap((output) =>
  (output.imports ?? []).filter((item) => item.external).map((item) => item.path)
))].sort();
const packageList = [...packages.values()].sort((a, b) => a.path.localeCompare(b.path));
const inventory = {
  schema: 1,
  server_sha256: createHash("sha256").update(readFileSync(bundlePath)).digest("hex"),
  input_count: inputs.length,
  packages: packageList,
  packages_without_license_notice: packageList.filter((item) => item.license_notice_files.length === 0),
  external_imports: externals,
  unresolved_inputs: unresolved,
  inputs,
  limitations: "Build input metadata and local license filenames only; native transitive components, license terms, notices and source obligations require separate review.",
};
process.stdout.write(JSON.stringify(inventory, null, 2) + "\n");
