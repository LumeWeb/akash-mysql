-- Create replication user with SSL requirement
CREATE USER IF NOT EXISTS '$MYSQL_REPL_USERNAME'@'%'
    IDENTIFIED WITH caching_sha2_password BY '$MYSQL_REPL_PASSWORD'
    REQUIRE SSL;

-- Grant necessary privileges for replication
GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPL_USERNAME'@'%';
GRANT REPLICATION CLIENT ON *.* TO '$MYSQL_REPL_USERNAME'@'%';
GRANT REPLICATION_SLAVE_ADMIN ON *.* TO '$MYSQL_REPL_USERNAME'@'%';
GRANT RELOAD ON *.* TO '$MYSQL_REPL_USERNAME'@'%';

FLUSH PRIVILEGES;
