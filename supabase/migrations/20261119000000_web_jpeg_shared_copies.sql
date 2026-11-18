-- Web uploads make shared copies in the browser, where canvas encodes JPEG rather than HEIC.
-- Object paths stay {adder}/{photo}/{rev}/{s|m|l}.heic so shipped iOS builds sign, cache and
-- delete them without knowing where a photo came from (ImageIO decodes from the bytes, not the
-- extension). Size limit (5 MB) and folder policies are unchanged.

update storage.buckets
   set allowed_mime_types = array['image/heic', 'image/jpeg']
 where id = 'media';
