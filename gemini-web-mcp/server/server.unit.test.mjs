import { beforeEach, describe, expect, it, vi } from "vitest";

let registeredTool;
let mockProvider;

const mockCache = {
  get: vi.fn(() => null),
  set: vi.fn(),
};

vi.mock("@modelcontextprotocol/sdk/server/mcp.js", () => {
  class MockMcpServer {
    registerTool(name, config, handler) {
      registeredTool = { name, config, handler };
    }

    async connect() {
      return;
    }
  }

  return { McpServer: MockMcpServer };
});

vi.mock("@modelcontextprotocol/sdk/server/stdio.js", () => {
  class MockTransport {}
  return { StdioServerTransport: MockTransport };
});

vi.mock("./providers/index.mjs", () => ({
  getProvider: vi.fn(() => mockProvider),
}));

vi.mock("./lib/cache.mjs", () => mockCache);
vi.mock("./lib/logger.mjs", () => ({
  debug: vi.fn(),
  info: vi.fn(),
  warn: vi.fn(),
  error: vi.fn(),
}));

async function loadWebSearchTool() {
  registeredTool = null;
  vi.resetModules();

  mockProvider = {
    getName: vi.fn(() => "gemini"),
    search: vi.fn(),
  };

  await import("./server.mjs");

  if (!registeredTool) {
    throw new Error("web_search tool was not registered");
  }

  return registeredTool;
}

describe("server.mjs web_search tool", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockCache.get.mockReturnValue(null);
  });

  it("registers web_search with expected schema", async () => {
    const tool = await loadWebSearchTool();

    expect(tool.name).toBe("web_search");
    expect(tool.config.inputSchema.query.parse("latest ai news")).toBe("latest ai news");
    expect(tool.config.inputSchema.max_results.parse(undefined)).toBe(5);
  });

  it("enforces query length limits", async () => {
    const tool = await loadWebSearchTool();

    expect(tool.config.inputSchema.query.safeParse("").success).toBe(false);
    expect(tool.config.inputSchema.query.safeParse("x".repeat(500)).success).toBe(true);
    expect(tool.config.inputSchema.query.safeParse("x".repeat(501)).success).toBe(false);
  });

  it("enforces max_results bounds", async () => {
    const tool = await loadWebSearchTool();

    expect(tool.config.inputSchema.max_results.safeParse(0).success).toBe(false);
    expect(tool.config.inputSchema.max_results.safeParse(1).success).toBe(true);
    expect(tool.config.inputSchema.max_results.safeParse(10).success).toBe(true);
    expect(tool.config.inputSchema.max_results.safeParse(11).success).toBe(false);
  });

  it("uses mocked provider API call and returns formatted response", async () => {
    const tool = await loadWebSearchTool();
    mockProvider.search.mockResolvedValue({
      summary: "Mocked summary",
      sources: [{ title: "Example", url: "https://example.com" }],
    });

    const result = await tool.handler({
      query: "   <b>AI   updates</b>   ",
      max_results: 3,
    });

    expect(mockProvider.search).toHaveBeenCalledWith("AI updates", 3);
    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain("Mocked summary");
    expect(result.content[0].text).toContain("Sources:\n1. Example - https://example.com");
  });
});
