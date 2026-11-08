import { asaasFetch } from "./asaas.ts";

// /transfers does not document an externalReference filter. Filter the bounded,
// paginated result locally; never use a partial/ambiguous result to resend money.
export async function findTransferByReference(
  reference: string,
  createdAt: string,
  key?: string
): Promise<string | null> {
  const date = new Date(createdAt);
  if (!Number.isFinite(date.getTime())) return null;
  const from = new Date(date.getTime() - 86400000).toISOString().slice(0, 10);
  const to = new Date(date.getTime() + 2 * 86400000).toISOString().slice(0, 10);
  const matches: string[] = [];
  for (let page = 0; page < 10; page++) {
    const response = await asaasFetch(
      `/transfers?dateCreated[ge]=${from}&dateCreated[le]=${to}&offset=${
        page * 100
      }&limit=100`,
      { key }
    );
    if (!response.ok)
      throw new Error("Consulta de transferências indisponível.");
    const result = (await response.json()) as {
      data?: Array<{ id?: string; externalReference?: string }>;
      hasMore?: boolean;
    };
    if (!Array.isArray(result.data)) throw new Error("Listagem inválida.");
    for (const transfer of result.data)
      if (transfer.externalReference === reference && transfer.id)
        matches.push(transfer.id);
    if (matches.length > 1) return null;
    if (result.hasMore === false)
      return matches.length === 1 ? matches[0] : null;
  }
  return null;
}
