#!/bin/bash
# Example requests for testing the bigeye-kong-plugin locally.
# Start Kong first: see scripts/start.sh and README.md.

# LLM: chat completion (AI Gateway / OpenAI-compatible)
curl -i -X POST "http://localhost:8000/v1/chat/completions" \
  -H "apikey: my-secret-api-key" \
  -H "Content-Type: application/json" \
  -H "x-conversation-id: conv-abc123" \
  -H "x-agent-id: agent-xyz" \
  -d '{"model": "gpt-4", "messages": [{"role": "user", "content": "What are the top customers by revenue?"}]}'

# MCP: tool call (Model Context Protocol, JSON-RPC)
curl -i -X POST "http://localhost:8000/query" \
  -H "apikey: my-secret-api-key" \
  -H "Content-Type: application/json" \
  -H "x-conversation-id: conv-abc123" \
  -d '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "query_database", "arguments": {"query": "SELECT * FROM customers", "database": "analytics"}}, "id": 1}'

# A2A: agent-to-agent message (Google A2A protocol)
curl -i -X POST "http://localhost:8000/query" \
  -H "apikey: my-secret-api-key" \
  -H "Content-Type: application/json" \
  -H "x-agent-id: data-agent-001" \
  -H "x-conversation-id: session-789" \
  -d '{"role": "user", "parts": [{"text": "Retrieve customer purchase history"}]}'

# Classic: SQL query via query parameter
curl -i "http://localhost:8000/query?sql=SELECT+*+FROM+users&database=production" \
  -H "apikey: my-secret-api-key"
