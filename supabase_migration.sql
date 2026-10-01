-- ============================================================
-- ClipSync: Supabase SQL Migration Script
-- ============================================================
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor)
-- ============================================================

-- 1. Create the clipboard_items table
CREATE TABLE IF NOT EXISTS public.clipboard_items (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id  TEXT        NOT NULL,
  content    TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Create index for fast user-scoped queries
CREATE INDEX IF NOT EXISTS idx_clipboard_items_user_id
  ON public.clipboard_items (user_id, created_at DESC);

-- 3. Enable Row Level Security
ALTER TABLE public.clipboard_items ENABLE ROW LEVEL SECURITY;

-- 4. RLS Policies: users can only access their own rows
CREATE POLICY "Users can read own clipboard items"
  ON public.clipboard_items
  FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own clipboard items"
  ON public.clipboard_items
  FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete own clipboard items"
  ON public.clipboard_items
  FOR DELETE
  USING (auth.uid() = user_id);

-- 5. Enable Realtime for this table
-- In Supabase Dashboard: Database > Replication > enable for clipboard_items
-- Or via SQL:
ALTER PUBLICATION supabase_realtime ADD TABLE public.clipboard_items;

-- 6. 48-Hour TTL Cleanup using pg_cron
-- NOTE: pg_cron must be enabled in your Supabase project (Dashboard > Database > Extensions)
-- Enable the extension first:
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule cleanup every hour to delete rows older than 48 hours
SELECT cron.schedule(
  'cleanup-old-clipboard-items',   -- job name
  '0 * * * *',                      -- every hour at minute 0
  $$DELETE FROM public.clipboard_items WHERE created_at < now() - interval '48 hours'$$
);
