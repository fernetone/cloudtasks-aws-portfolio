import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
export async function withAwsJsonInput(input, operation) {
  if (input === undefined) return await operation([]);
  const directory = await mkdtemp(path.join(tmpdir(), "cloudtasks-mcp-input-"));
  try {
    const file = path.join(directory, "input.json");
    await writeFile(file, JSON.stringify(input), { mode: 0o600, flag: "wx" });
    return await operation(["--cli-input-json", "file://" + file]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
