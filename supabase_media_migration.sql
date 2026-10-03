-- ============================================================
-- ClipSync: image & file sync migration
-- ============================================================
-- Run this ONCE in the Supabase SQL Editor (after supabase_migration.sql).
-- Text sync keeps working without it; images/files need it.
-- ============================================================

-- 1. Columns describing image/file items
ALTER TABLE public.clipboard_items
  ADD COLUMN IF NOT EXISTS kind         TEXT   NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS file_name    TEXT,
  ADD COLUMN IF NOT EXISTS mime_type    TEXT,
  ADD COLUMN IF NOT EXISTS size_bytes   BIGINT,
  ADD COLUMN IF NOT EXISTS storage_path TEXT;

ALTER TABLE public.clipboard_items
  DROP CONSTRAINT IF EXISTS clipboard_items_kind_check;
ALTER TABLE public.clipboard_items
  ADD CONSTRAINT clipboard_items_kind_check
  CHECK (kind IN ('text', 'image', 'file'));

-- 2. Private storage bucket (10 MB per file)
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('clipboard-files', 'clipboard-files', false, 10485760)
ON CONFLICT (id) DO UPDATE SET file_size_limit = EXCLUDED.file_size_limit;

-- 3. Storage policies: each user may only touch files under "<their user id>/"
DROP POLICY IF EXISTS "Users can upload own clipboard files" ON storage.objects;
CREATE POLICY "Users can upload own clipboard files"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'clipboard-files'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "Users can read own clipboard files" ON storage.objects;
CREATE POLICY "Users can read own clipboard files"
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'clipboard-files'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "Users can delete own clipboard files" ON storage.objects;
CREATE POLICY "Users can delete own clipboard files"
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'clipboard-files'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- 4. 48-hour cleanup: only TEXT rows are deleted here.
-- Rows that point at a stored file are removed by the app through the Storage
-- API (Supabase doesn't allow deleting storage objects with plain SQL, and
-- deleting only the row would leave the file behind).
SELECT cron.schedule(
  'cleanup-old-clipboard-items',
  '0 * * * *',
  $$DELETE FROM public.clipboard_items
    WHERE created_at < now() - interval '48 hours'
      AND storage_path IS NULL$$
);
