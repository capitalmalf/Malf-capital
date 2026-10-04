-- =====================================================================
-- CRM Malf Capital - configuração do Supabase
-- Cole TUDO no SQL Editor do Supabase e clique em RUN.
-- ANTES: troque os e-mails na linha "insert into usuarios_autorizados".
-- =====================================================================

-- 1) Tabela de clientes ------------------------------------------------
create table if not exists public.clientes (
  id                  uuid primary key default gen_random_uuid(),
  nome                text not null,
  cpf                 text not null default '',
  nascimento          date,
  telefone            text not null default '',
  whatsapp            text not null default 'Sim',
  email               text not null default '',
  valor               numeric(14,2) not null default 0,
  status              text not null default 'Em negociação',
  observacoes         text not null default '',
  proximo_contato     date,
  situacao_receita    text,
  situacao_receita_em date,
  documentos          jsonb not null default '[]'::jsonb,
  timeline            jsonb not null default '[]'::jsonb,
  historico           jsonb not null default '[]'::jsonb,
  criado_em           timestamptz not null default now()
);

-- 2) Quem pode acessar (lista de e-mails autorizados) ------------------
create table if not exists public.usuarios_autorizados (email text primary key);
alter table public.usuarios_autorizados enable row level security;  -- sem políticas = ninguém lê pelo site

insert into public.usuarios_autorizados (email) values
  ('capitalmalf@gmail.com')            -- <<< TROQUE (adicione uma linha por pessoa, separadas por vírgula)
on conflict do nothing;

create or replace function public.autorizado() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.usuarios_autorizados
                 where lower(email) = lower(auth.jwt() ->> 'email'));
$$;

-- 3) Segurança por linha (RLS) ------------------------------------------
alter table public.clientes enable row level security;

drop policy if exists "autorizados fazem tudo" on public.clientes;
create policy "autorizados fazem tudo" on public.clientes
  for all to authenticated
  using (public.autorizado()) with check (public.autorizado());

-- 4) Funções usadas pelo site (adicionar item / remover documento) ------
create or replace function public.append_item(p_id uuid, p_campo text, p_item jsonb)
returns void language plpgsql security invoker as $$
begin
  if p_campo not in ('timeline','historico','documentos') then
    raise exception 'campo inválido';
  end if;
  execute format('update public.clientes set %I = %I || jsonb_build_array($1) where id = $2', p_campo, p_campo)
    using p_item, p_id;
end $$;

create or replace function public.remover_documento(p_id uuid, p_path text)
returns void language sql security invoker as $$
  update public.clientes
     set documentos = coalesce((select jsonb_agg(e) from jsonb_array_elements(documentos) e
                                where e ->> 'path' <> p_path), '[]'::jsonb)
   where id = p_id;
$$;

-- 5) Atualização em tempo real -------------------------------------------
alter publication supabase_realtime add table public.clientes;

-- 6) Armazenamento de documentos (bucket privado) ------------------------
insert into storage.buckets (id, name, public) values ('documentos', 'documentos', false)
on conflict (id) do nothing;

drop policy if exists "documentos autorizados" on storage.objects;
create policy "documentos autorizados" on storage.objects
  for all to authenticated
  using (bucket_id = 'documentos' and public.autorizado())
  with check (bucket_id = 'documentos' and public.autorizado());
