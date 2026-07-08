import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/**/*.test.ts"],
    // The suite drives one shared cluster; parallel files would race VM state.
    fileParallelism: false,
    testTimeout: 30_000,
    reporters: ["default", ["junit", { outputFile: "junit.xml" }]],
  },
});
