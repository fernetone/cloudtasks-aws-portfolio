export async function closeMcpSessions(sessions) {
  const outcomes = [];
  for (const { name, client, transport } of [...sessions].reverse()) {
    const result = { name, clientClosed: false, transportClosed: false };
    try {
      await client.close();
      result.clientClosed = true;
    } catch {
      /* report only closure state */
    }
    try {
      await transport.close();
      result.transportClosed = true;
    } catch {
      /* still close the other sessions */
    }
    outcomes.push(result);
  }
  if (outcomes.some((x) => !x.clientClosed || !x.transportClosed)) {
    const error = Error("MCP_SESSION_CLOSE_FAILED");
    error.outcomes = outcomes;
    throw error;
  }
  return outcomes;
}
