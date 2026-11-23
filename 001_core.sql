-- =====================================================================
-- 001_core.sql  |  نظام التسجيل  |  قابل لإعادة التشغيل بأمان (idempotent)
-- شغّله كاملاً مرة واحدة في Supabase: SQL Editor > New query > Run
-- =====================================================================
create extension if not exists pgcrypto;

-- ---------- 1) جداول مرجعية ----------
create table if not exists governorates (name text primary key);
insert into governorates(name) values
('القاهرة'),('الجيزة'),('الإسكندرية'),('القليوبية'),('البحيرة'),('مطروح'),('كفر الشيخ'),('الغربية'),('المنوفية'),
('الدقهلية'),('دمياط'),('الشرقية'),('بورسعيد'),('الإسماعيلية'),('السويس'),('شمال سيناء'),('جنوب سيناء'),('الفيوم'),
('بني سويف'),('المنيا'),('أسيوط'),('سوهاج'),('قنا'),('الأقصر'),('أسوان'),('البحر الأحمر'),('الوادي الجديد')
on conflict do nothing;

create table if not exists nid_governorate_codes (code text primary key check (code ~ '^[0-9]{2}$'), name text not null);
insert into nid_governorate_codes(code,name) values
('01','القاهرة'),('02','الإسكندرية'),('03','بورسعيد'),('04','السويس'),('11','دمياط'),('12','الدقهلية'),('13','الشرقية'),
('14','القليوبية'),('15','كفر الشيخ'),('16','الغربية'),('17','المنوفية'),('18','البحيرة'),('19','الإسماعيلية'),('21','الجيزة'),
('22','بني سويف'),('23','الفيوم'),('24','المنيا'),('25','أسيوط'),('26','سوهاج'),('27','قنا'),('28','أسوان'),('29','الأقصر'),
('31','البحر الأحمر'),('32','الوادي الجديد'),('33','مطروح'),('34','شمال سيناء'),('35','جنوب سيناء'),('88','خارج الجمهورية')
on conflict do nothing;

-- ---------- 2) الإعدادات ----------
create table if not exists system_settings (
  id int primary key default 1 check (id = 1),
  registration_limit int not null default 100 check (registration_limit >= 0),
  registration_enabled boolean not null default true,
  whatsapp_group_link text not null default '',
  closed_message text not null default 'نشكرك على اهتمامك بالتسجيل. نعتذر، لقد اكتمل العدد المحدد للتسجيل حالياً. تابعنا لمعرفة موعد فتح التسجيل مرة أخرى.',
  success_message text not null default 'تم استلام بياناتك بنجاح، وسيتم مراجعتها من قبل فريق الإدارة.',
  system_name text not null default 'اتحاد طلاب تحيا مصر',
  logo_url text not null default '',
  updated_at timestamptz not null default now()
);
insert into system_settings(id) values (1) on conflict do nothing;
-- لو الجدول موجود مسبقاً بالاسم القديم، حدّثه: update system_settings set system_name='اتحاد طلاب تحيا مصر' where id=1 and system_name='نظام التسجيل';

-- ---------- 3) المسجلون ----------
create table if not exists registrants (
  id uuid primary key default gen_random_uuid(),
  registration_number bigint not null unique check (registration_number > 0),
  full_name text not null check (char_length(full_name) between 5 and 150),
  national_id text not null unique check (national_id ~ '^[23][0-9]{13}$'),
  birth_date date not null,
  gender text not null check (gender in ('ذكر','أنثى')),
  national_id_governorate text not null,
  residence_governorate text not null references governorates(name),
  education_level text not null check (education_level in ('ثانوي','جامعي','فوق جامعي')),
  school_name text check (char_length(school_name) <= 150),
  university_name text check (char_length(university_name) <= 150),
  faculty_name text check (char_length(faculty_name) <= 150),
  postgraduate_degree text check (char_length(postgraduate_degree) <= 150),
  phone_normalized text not null unique check (phone_normalized ~ '^1[0125][0-9]{8}$'),
  whatsapp_normalized text not null unique check (whatsapp_normalized ~ '^1[0125][0-9]{8}$'),
  email_normalized text not null unique check (email_normalized ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email_normalized) <= 200),
  application_status text not null default 'جديد'
    check (application_status in ('جديد','قيد المراجعة','مقبول','مرفوض','يحتاج إلى استكمال بيانات')),
  privacy_consent boolean not null check (privacy_consent),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint edu_fields_ok check (
    (education_level = 'ثانوي' and school_name is not null and university_name is null and faculty_name is null and postgraduate_degree is null) or
    (education_level = 'جامعي' and university_name is not null and faculty_name is not null and school_name is null and postgraduate_degree is null) or
    (education_level = 'فوق جامعي' and university_name is not null and faculty_name is not null and postgraduate_degree is not null and school_name is null))
);
create index if not exists registrants_status_created_idx on registrants (application_status, created_at desc);
create index if not exists registrants_created_idx on registrants (created_at desc);
create index if not exists registrants_gov_idx on registrants (residence_governorate);

-- ---------- 4) الإداريون وسجل النشاط ----------
create table if not exists admin_users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  role text not null check (role in ('super_admin','admin','viewer')),
  created_at timestamptz not null default now()
);
create table if not exists activity_logs (
  id bigint generated always as identity primary key,
  admin_id uuid references admin_users(id) on delete set null,
  action text not null, entity_type text, entity_id text, details jsonb,
  created_at timestamptz not null default now()
);
create index if not exists activity_logs_created_idx on activity_logs (created_at desc);

-- عداد عام لا يحوي أي بيانات شخصية (يُبث عبر Realtime)
create table if not exists public_counter (id int primary key default 1 check (id = 1), total int not null default 0);
insert into public_counter(id,total) values (1,(select count(*) from registrants)) on conflict do nothing;

-- ---------- 5) دوال مساعدة وتريغرات ----------
create or replace function admin_role() returns text language sql stable security definer set search_path = public, pg_temp as
$$ select role from admin_users where auth_user_id = auth.uid() $$;

create or replace function touch_updated_at() returns trigger language plpgsql as
$$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists trg_reg_touch on registrants;
create trigger trg_reg_touch before update on registrants for each row execute function touch_updated_at();
drop trigger if exists trg_set_touch on system_settings;
create trigger trg_set_touch before update on system_settings for each row execute function touch_updated_at();

create or replace function sync_counter() returns trigger language plpgsql security definer set search_path = public, pg_temp as
$$ begin update public_counter set total = (select count(*) from registrants) where id = 1; return null; end $$;
drop trigger if exists trg_counter on registrants;
create trigger trg_counter after insert or delete on registrants for each statement execute function sync_counter();

-- تدقيق تلقائي: تغيير الحالة والحذف (بدون أي بيانات حساسة)
create or replace function audit_registrant() returns trigger language plpgsql security definer set search_path = public, pg_temp as
$$ declare a uuid := (select id from admin_users where auth_user_id = auth.uid());
begin
  if tg_op = 'DELETE' then
    insert into activity_logs(admin_id,action,entity_type,entity_id,details)
    values (a,'delete','registrant',old.registration_number::text,'{}'::jsonb); return old;
  elsif old.application_status is distinct from new.application_status then
    insert into activity_logs(admin_id,action,entity_type,entity_id,details)
    values (a,'status_change','registrant',new.registration_number::text,
            jsonb_build_object('from',old.application_status,'to',new.application_status));
  end if; return new;
end $$;
drop trigger if exists trg_audit on registrants;
create trigger trg_audit after update or delete on registrants for each row execute function audit_registrant();

-- تسجيل عمليات حساسة من الواجهة (عرض/تصدير/استيراد)
create or replace function log_activity(p_action text, p_entity text default null, p_entity_id text default null, p_details jsonb default '{}')
returns void language plpgsql security definer set search_path = public, pg_temp as
$$ begin
  if admin_role() is null then raise exception 'forbidden'; end if;
  insert into activity_logs(admin_id,action,entity_type,entity_id,details)
  values ((select id from admin_users where auth_user_id = auth.uid()), left(p_action,60), left(p_entity,60), left(p_entity_id,60), p_details);
end $$;

-- ---------- 6) الصلاحيات و RLS ----------
alter table governorates enable row level security;
alter table nid_governorate_codes enable row level security;
alter table system_settings enable row level security;
alter table registrants enable row level security;
alter table admin_users enable row level security;
alter table activity_logs enable row level security;
alter table public_counter enable row level security;

revoke all on all tables in schema public from anon;
grant select on public_counter to anon, authenticated;
grant select on governorates, nid_governorate_codes to authenticated;
grant select, update, delete on registrants to authenticated;
grant select, update on system_settings to authenticated;
grant select, insert, update, delete on admin_users to authenticated;
grant select on activity_logs to authenticated;

drop policy if exists counter_read on public_counter;
create policy counter_read on public_counter for select to anon, authenticated using (true);
drop policy if exists ref_gov on governorates;
create policy ref_gov on governorates for select to authenticated using (true);
drop policy if exists ref_nid on nid_governorate_codes;
create policy ref_nid on nid_governorate_codes for select to authenticated using (true);

drop policy if exists reg_read on registrants;
create policy reg_read on registrants for select to authenticated using (admin_role() is not null);
drop policy if exists reg_update on registrants;
create policy reg_update on registrants for update to authenticated
  using (admin_role() in ('super_admin','admin')) with check (admin_role() in ('super_admin','admin'));
drop policy if exists reg_delete on registrants;
create policy reg_delete on registrants for delete to authenticated using (admin_role() = 'super_admin');

drop policy if exists set_read on system_settings;
create policy set_read on system_settings for select to authenticated using (admin_role() is not null);
drop policy if exists set_write on system_settings;
create policy set_write on system_settings for update to authenticated
  using (admin_role() = 'super_admin') with check (admin_role() = 'super_admin');

drop policy if exists adm_self on admin_users;
create policy adm_self on admin_users for select to authenticated using (auth_user_id = auth.uid());
drop policy if exists adm_manage on admin_users;
create policy adm_manage on admin_users for all to authenticated
  using (admin_role() = 'super_admin') with check (admin_role() = 'super_admin');

drop policy if exists log_read on activity_logs;
create policy log_read on activity_logs for select to authenticated using (admin_role() is not null);

-- ---------- 7) واجهة التسجيل العامة (RPC) ----------
create or replace function public_status() returns jsonb language sql stable security definer set search_path = public, pg_temp as
$$ select jsonb_build_object('total', c.total, 'limit', s.registration_limit,
     'open', (s.registration_enabled and c.total < s.registration_limit),
     'closed_message', s.closed_message, 'system_name', s.system_name, 'logo_url', s.logo_url)
   from public_counter c cross join system_settings s where c.id = 1 and s.id = 1 $$;

create or replace function register_applicant(p jsonb) returns jsonb language plpgsql security definer set search_path = public, pg_temp as
$$
declare
  s system_settings; n int;
  nid text; v_name text; ph text; wa text; em text; edu text; res text;
  sch text; uni text; fac text; pg text;
  yr int; bd date; gov text; gen text; rn bigint;
  digits constant text := '٠١٢٣٤٥٦٧٨٩';
begin
  if p is null or jsonb_typeof(p) <> 'object' then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;

  -- قفل صف الإعدادات: يمنع تجاوز الحد عند التسجيل المتزامن
  select * into s from system_settings where id = 1 for update;
  select count(*) into n from registrants;
  if not s.registration_enabled or n >= s.registration_limit then
    return jsonb_build_object('ok', false, 'error', 'closed', 'message', s.closed_message);
  end if;

  nid  := translate(coalesce(p->>'national_id',''), digits, '0123456789');
  v_name := regexp_replace(trim(coalesce(p->>'full_name','')), '\s+', ' ', 'g');
  ph   := regexp_replace(regexp_replace(translate(coalesce(p->>'phone',''),    digits, '0123456789'), '[^0-9]', '', 'g'), '^(0020|20|0)', '');
  wa   := regexp_replace(regexp_replace(translate(coalesce(p->>'whatsapp',''), digits, '0123456789'), '[^0-9]', '', 'g'), '^(0020|20|0)', '');
  em   := lower(trim(coalesce(p->>'email','')));
  edu  := p->>'education_level';  res := p->>'residence_governorate';
  sch  := nullif(trim(coalesce(p->>'school_name','')),'');
  uni  := nullif(trim(coalesce(p->>'university_name','')),'');
  fac  := nullif(trim(coalesce(p->>'faculty_name','')),'');
  pg   := nullif(trim(coalesce(p->>'postgraduate_degree','')),'');

  if coalesce(p->>'privacy_consent','') <> 'true'
     or nid !~ '^[23][0-9]{13}$'
     or v_name !~ '^[ء-ي ]+$' or array_length(string_to_array(v_name,' '),1) < 2 or char_length(v_name) > 150
     or ph !~ '^1[0125][0-9]{8}$' or wa !~ '^1[0125][0-9]{8}$'
     or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(em) > 200
     or not exists (select 1 from governorates where governorates.name = res)
     or edu not in ('ثانوي','جامعي','فوق جامعي') then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end if;

  -- مطابقة الحقول مع المؤهل (الحقول غير ذات الصلة تُهمل)
  if edu = 'ثانوي' then
    if sch is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
    uni := null; fac := null; pg := null;
  elsif edu = 'جامعي' then
    if uni is null or fac is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
    sch := null; pg := null;
  else
    if uni is null or fac is null or pg is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
    sch := null;
  end if;
  if char_length(coalesce(sch,uni,'')) > 150 or char_length(coalesce(fac,'')) > 150 or char_length(coalesce(pg,'')) > 150 then
    return jsonb_build_object('ok', false, 'error', 'invalid'); end if;

  -- استخراج بيانات الرقم القومي من الخادم (لا نثق بما يرسله المتصفح)
  begin
    yr := (case substr(nid,1,1) when '2' then 1900 else 2000 end) + substr(nid,2,2)::int;
    bd := make_date(yr, substr(nid,4,2)::int, substr(nid,6,2)::int);   -- يرفض التواريخ المستحيلة
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'invalid');
  end;
  if bd > current_date then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  select c.name into gov from nid_governorate_codes c where c.code = substr(nid,8,2);
  if gov is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  gen := case when substr(nid,13,1)::int % 2 = 1 then 'ذكر' else 'أنثى' end;

  -- أصغر رقم تسجيل غير مستخدم (يعيد استخدام أرقام السجلات المحذوفة؛ آمن لأن صف الإعدادات مقفول)
  select g into rn from generate_series(1, n + 1) g
    where not exists (select 1 from registrants r where r.registration_number = g) order by g limit 1;

  insert into registrants(registration_number, full_name, national_id, birth_date, gender, national_id_governorate, residence_governorate,
      education_level, school_name, university_name, faculty_name, postgraduate_degree,
      phone_normalized, whatsapp_normalized, email_normalized, privacy_consent)
  values (rn, v_name, nid, bd, gen, gov, res, edu, sch, uni, fac, pg, ph, wa, em, true);

  return jsonb_build_object('ok', true, 'registration_number', rn,
                            'whatsapp_link', s.whatsapp_group_link, 'message', s.success_message);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'duplicate');
end
$$;

revoke all on function register_applicant(jsonb), public_status(), log_activity(text,text,text,jsonb) from public;
grant execute on function register_applicant(jsonb), public_status() to anon, authenticated;
grant execute on function log_activity(text,text,text,jsonb), admin_role() to authenticated;

-- ---------- 8) Realtime ----------
do $$ begin alter publication supabase_realtime add table public_counter;  exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table registrants;      exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table system_settings;  exception when duplicate_object then null; end $$;

-- ---------- 9) حسابات الإدارة التجريبية ----------
-- أنشئ هذه الحسابات يدوياً من: Authentication > Users > Add user (مع Auto Confirm)
-- بمجرد إنشاء الحساب بنفس البريد يحصل تلقائياً على الدور المحدد هنا.
-- لتغيير البريد أو الدور لاحقاً: عدّل الصفوف في admin_seed ثم شغّل أمر التحديث في آخر هذا القسم.
create table if not exists admin_seed (
  email text primary key,
  role text not null check (role in ('super_admin','admin','viewer'))
);
alter table admin_seed enable row level security;   -- بلا سياسات: لا يصل إليه إلا مدير قاعدة البيانات
revoke all on admin_seed from anon, authenticated;

insert into admin_seed(email, role) values
  ('super.admin@example.com', 'super_admin'),   -- بريد تجريبي: غيّره لبريدك
  ('admin@example.com',       'admin'),         -- بريد تجريبي
  ('viewer@example.com',      'viewer')         -- بريد تجريبي
on conflict (email) do update set role = excluded.role;

-- ربط تلقائي عند إنشاء مستخدم جديد
create or replace function link_admin_from_seed() returns trigger language plpgsql security definer set search_path = public, pg_temp as
$$ begin
  insert into admin_users(auth_user_id, role)
  select new.id, sd.role from admin_seed sd where lower(sd.email) = lower(new.email)
  on conflict (auth_user_id) do update set role = excluded.role;
  return new;
end $$;
drop trigger if exists trg_link_admin on auth.users;
create trigger trg_link_admin after insert on auth.users for each row execute function link_admin_from_seed();

-- ربط/تحديث المستخدمين الموجودين فعلاً (شغّله مرة أخرى بعد أي تعديل في admin_seed)
insert into admin_users(auth_user_id, role)
select u.id, sd.role from auth.users u join admin_seed sd on lower(sd.email) = lower(u.email)
on conflict (auth_user_id) do update set role = excluded.role;

-- تنبيه أمني: عطّل "Allow new users to sign up" من Authentication > Providers > Email،
-- حتى لا يستطيع أحد إنشاء حساب ببريد من القائمة أعلاه والحصول على صلاحيات.
-- وبعد ربط بريدك الحقيقي احذف الصفوف التجريبية: delete from admin_seed where email like '%@example.com';
