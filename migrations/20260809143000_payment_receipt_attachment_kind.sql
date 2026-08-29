-- Comprovantes de PIX são anexos privados separados das fotos e áudios do
-- problema, para que possam ser identificados e exibidos no atendimento.
alter type public.attachment_kind add value if not exists 'payment_receipt';
