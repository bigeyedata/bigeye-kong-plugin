#!/bin/bash
# Example requests for testing the bigeye-kong-plugin locally.
# Start Kong first: see scripts/start.sh and README.md.

# LLM: chat completion (AI Gateway / OpenAI-compatible)
# x-initial-prompt carries the first user message that opened the conversation.
# x-username identifies the end user (used to link the conversation to a Bigeye user).
# x-ai-agent-description is stored on the agent record when Bigeye auto-creates it.
curl -i -X POST "http://localhost:8000/v1/chat/completions" \
  -H "apikey: my-secret-api-key" \
  -H "Content-Type: application/json" \
  -H "x-conversation-id: conv-abc123" \
  -H "x-agent-id: agent-xyz" \
  -H "x-ai-agent-id: ai-agent-001" \
  -H "x-ai-agent-description: Customer analytics assistant" \
  -H "x-initial-prompt: What are the top customers by revenue?" \
  -H "x-username: alice@example.com" \
  -d '{"model": "gpt-4", "messages": [{"role": "user", "content": "What are the top customers by revenue?"}]}'

# LLM: follow-up turn in the same conversation.
# Omit x-initial-prompt on subsequent turns; the plugin falls back to the first
# role=user message in body.messages, which is the original opening message.
curl -i -X POST "http://localhost:8000/v1/chat/completions" \
  -H "apikey: my-secret-api-key" \
  -H "Content-Type: application/json" \
  -H "x-conversation-id: conv-abc123" \
  -H "x-agent-id: agent-xyz" \
  -H "x-username: alice@example.com" \
  -d '{"model": "gpt-4", "messages": [{"role": "user", "content": "What are the top customers by revenue?"}, {"role": "assistant", "content": "Here are the top customers..."}, {"role": "user", "content": "Now filter by region"}]}'

# MCP: tool call (Model Context Protocol, JSON-RPC)
curl -i -X POST "http://localhost:8000/query" \
  -H "apikey: my-secret-api-key" \
  -H "Content-Type: application/json" \
  -H "x-conversation-id: conv-abc123" \
  -H "x-username: alice@example.com" \
  -H "x-initial-prompt: What are the top customers by revenue?" \
  -d '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "query_database", "arguments": {"query": "SELECT * FROM customers", "database": "analytics"}}, "id": 1}'

# A2A: agent-to-agent message (Google A2A protocol)
curl -i -X POST "http://localhost:8000/query" \
  -H "apikey: my-secret-api-key" \
  -H "Content-Type: application/json" \
  -H "x-agent-id: data-agent-001" \
  -H "x-ai-agent-id: orchestrator-001" \
  -H "x-ai-agent-description: Orchestrator agent for customer analytics" \
  -H "x-conversation-id: session-789" \
  -H "x-username: alice@example.com" \
  -H "x-initial-prompt: Retrieve customer purchase history" \
  -d '{"role": "user", "parts": [{"text": "Retrieve customer purchase history"}]}'

# Classic: SQL query via query parameter
curl -i "http://localhost:8000/query?sql=SELECT+*+FROM+users&database=production" \
  -H "apikey: my-secret-api-key"
