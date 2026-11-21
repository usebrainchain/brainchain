import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import ts from "typescript";

const root = fileURLToPath(new URL("..", import.meta.url));
const section = readFileSync(join(root, "README.md"), "utf8").split("\n## 0x quotes\n")[1].split("\n## ")[0];

describe("the README's 0x quotes", () => {
  it("compile under strict TypeScript against this build, as a reader would paste them", () => {
    const blocks = [...section.matchAll(/```ts\n([\s\S]*?)```/g)].map((match) => match[1]);
    assert.ok(blocks.length > 0);
    const options = {
      strict: true,
      noUncheckedIndexedAccess: true,
      noEmit: true,
      skipLibCheck: true,
      target: ts.ScriptTarget.ES2023,
      lib: ["lib.es2023.d.ts"],
      module: ts.ModuleKind.NodeNext,
      moduleResolution: ts.ModuleResolutionKind.NodeNext,
      types: ["node"],
    };
    // In the package's own folder, so the examples import brainchain-verify/zerox through its exports, as a reader's code does.
    const files = new Map(blocks.map((code, i) => [join(root, "test", `readme-example-${i}.ts`), code]));
    const host = ts.createCompilerHost(options);
    const { fileExists, readFile, getSourceFile } = host;
    host.fileExists = (name) => files.has(name) || fileExists(name);
    host.readFile = (name) => files.get(name) ?? readFile(name);
    host.getSourceFile = (name, language, ...rest) => (files.has(name) ? ts.createSourceFile(name, files.get(name), language) : getSourceFile(name, language, ...rest));
    const program = ts.createProgram([...files.keys()], options, host);
    const problems = ts.getPreEmitDiagnostics(program).map((d) => `${d.file ? `${d.file.fileName.split("/").pop()}:${d.file.getLineAndCharacterOfPosition(d.start ?? 0).line + 1} ` : ""}${ts.flattenDiagnosticMessageText(d.messageText, "\n")}`);
    assert.deepEqual(problems, []);
  });

  it("list in the table exactly the checks a report can name", async () => {
    const listed = [...section.matchAll(/^\| `([a-z-]+)` \|/gm)].map((match) => match[1]);
    const { checkQuote, verifyQuote } = await import("../dist/zerox.js");
    const f = JSON.parse(readFileSync(join(root, "test/fixtures/zerox/quote-exact-out-eth.json"), "utf8"));
    const body = Buffer.from(f.body, "base64");
    const json = JSON.parse(body.toString("utf8"));
    const q = new URL(f.url).searchParams;
    const intent = { chainId: 4663, taker: q.get("taker"), sellToken: q.get("sellToken"), buyToken: q.get("buyToken"), buyAmount: BigInt(q.get("buyAmount")), maxSellAmount: BigInt(json.maxSellAmount), maxGasCost: 10n ** 18n };
    const created = Number(/created=(\d+)/.exec(f.headers["signature-input"])[1]);
    const settlers = { current: "0xE8852602f84e04e284286d8Db01a41Edd0CCEFb0" };
    const report = await verifyQuote({ status: f.status, headers: f.headers, body }, f.url, intent, { settlers, now: () => (created + 1) * 1000 });
    assert.equal(report.ok, true, JSON.stringify(report.checks.find((c) => c.status === "fail")));
    assert.deepEqual(report.checks.map((c) => c.name), listed);
    assert.deepEqual(checkQuote(json, intent, settlers).checks.map((c) => c.name), listed.filter((name) => name.startsWith("quote-") && name !== "quote-request"));
  });
});
