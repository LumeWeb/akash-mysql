-- Set authentication policy and ensure only caching_sha2_password is used
SET PERSIST authentication_policy='caching_sha2_password';
SET PERSIST host_cache_size=0;
