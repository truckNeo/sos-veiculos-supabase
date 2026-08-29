-- A view é deliberadamente executada como proprietária para que a policy da
-- tabela sensível não exponha tokens; ela projeta somente o status seguro.
alter view public.my_iugu_account_status set (security_invoker = false);
grant select on public.my_iugu_account_status to authenticated;
