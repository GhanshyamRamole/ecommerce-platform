#!/bin/bash
set -euo pipefail

DB_NAME="${db_name}"
DB_USER="${db_user}"
DB_PASSWORD="${db_password}"
VPC_CIDR="${vpc_cidr}"

apt-get update -y
apt-get install -y postgresql postgresql-contrib

systemctl enable postgresql
systemctl start postgresql

# Use psql with proper escaping for password
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
CREATE USER "$DB_USER" WITH ENCRYPTED PASSWORD '$DB_PASSWORD';
CREATE DATABASE "$DB_NAME" OWNER "$DB_USER";
GRANT ALL PRIVILEGES ON DATABASE "$DB_NAME" TO "$DB_USER";
EOF

sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf
echo "host all all $VPC_CIDR md5" >> /etc/postgresql/*/main/pg_hba.conf

systemctl restart postgresql