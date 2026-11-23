-- 002_reuse_numbers.sql  |  لقاعدة بيانات تعمل بالفعل: رقم التسجيل يأخذ أصغر رقم فارغ
alter table registrants alter column registration_number drop identity if exists;
alter table registrants alter column registration_number set not null;
do $$ begin alter table registrants add constraint registration_number_pos check (registration_number > 0);
exception when duplicate_object then null; end $$;

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


grant execute on function register_applicant(jsonb) to anon, authenticated;
