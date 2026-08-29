-- Bucket privado para avatares de perfil.
-- O contrato de caminho é <user_id>/avatar.<ext>.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-avatars',
  'profile-avatars',
  false,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "user can upload own avatar"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'profile-avatars'
    and owner_id = auth.uid()::text
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "user can update own avatar"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'profile-avatars'
    and owner_id = auth.uid()::text
  );

create policy "authenticated users can read avatars"
  on storage.objects for select to authenticated
  using (bucket_id = 'profile-avatars');

create policy "user can delete own avatar"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'profile-avatars'
    and owner_id = auth.uid()::text
  );
