-- ============================================================================
-- Fix Storage Bucket Policies without ALTER TABLE storage.objects
-- (In Supabase, storage.objects already has RLS enabled by the system owner)
-- Run this in your Supabase SQL Editor:
-- https://supabase.com/dashboard/project/vrnqemqzmklrjpssneng/sql/new
-- ============================================================================

-- 1. Allow authenticated employees to upload receipts
DROP POLICY IF EXISTS "Authenticated users can upload receipts" ON storage.objects;
CREATE POLICY "Authenticated users can upload receipts"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'receipts'
);

-- 2. Allow authenticated employees to view receipts
DROP POLICY IF EXISTS "Authenticated users can view receipts" ON storage.objects;
CREATE POLICY "Authenticated users can view receipts"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'receipts'
);

-- 3. Allow authenticated employees to update receipts
DROP POLICY IF EXISTS "Authenticated users can update receipts" ON storage.objects;
CREATE POLICY "Authenticated users can update receipts"
ON storage.objects FOR UPDATE
TO authenticated
USING (
  bucket_id = 'receipts'
);

-- 4. Allow authenticated employees to delete receipts
DROP POLICY IF EXISTS "Authenticated users can delete receipts" ON storage.objects;
CREATE POLICY "Authenticated users can delete receipts"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'receipts'
);
