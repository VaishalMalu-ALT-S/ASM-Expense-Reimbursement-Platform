ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Recipients view their own notifications" ON notifications;
DROP POLICY IF EXISTS "Recipients update their own notifications" ON notifications;

CREATE POLICY "Recipients view their own notifications" ON notifications
FOR SELECT TO authenticated
USING (recipient_id = auth.uid());

CREATE POLICY "Recipients update their own notifications" ON notifications
FOR UPDATE TO authenticated
USING (recipient_id = auth.uid())
WITH CHECK (recipient_id = auth.uid());
