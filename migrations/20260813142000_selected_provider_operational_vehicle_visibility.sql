create policy "selected requesters can read provider operational vehicles"
  on public.provider_vehicles for select to authenticated
  using (
    exists (
      select 1 from public.service_requests request
      where request.requester_id = auth.uid()
        and request.selected_provider_id = provider_vehicles.provider_id
    )
  );
