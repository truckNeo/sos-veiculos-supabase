/** Celular no formato do Asaas: DDD + 9 dígitos, sem +55. Null se não for um celular válido. */
export function asaasMobilePhone(raw: string | null | undefined): string | null {
  let digits = (raw ?? "").replace(/\D/g, "");
  if (digits.length > 11 && digits.startsWith("55")) digits = digits.slice(2);
  return /^[1-9][1-9]9\d{8}$/.test(digits) ? digits : null;
}
