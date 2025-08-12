#Example do_gpdr 
# Degree of parallelism for pgbackrest
process_max=3
# Username (GreenPlum connection)
user="gpadmin"
# Greenplum connect port
port=5432
# GreenPlum master host
host="gpmas01n"
# Repository path for backup
repo_path="/gpbackup/local/pgbackrest/"
# Repository path for restore
restore_repo_path="/gpbackup/remote/pgbackrest/"
# pgbackrest config path
config_path="/etc/pgbackrest/"
# pgabckrest log level
log_level="info"
# What is this?
backup_sleep=0
repo_retention_full=2
auto_restart=true
# Repostories for each segment (for backup)
[backup_repo.-1]
host="gpmas01n"
[backup_repo.0]
host="gpseg01n"
[backup_repo.1]
host="gpseg01n"
[backup_repo.2]
host="gpseg01n"
[backup_repo.3]
host="gpseg01n"
[backup_repo.4]
host="gpseg02n"
[backup_repo.5]
host="gpseg02n"
[backup_repo.6]
host="gpseg02n"
[backup_repo.7]
host="gpseg02n"
# Repostories for each segment (for restore)
[restore_segments.-1]
user="gpadmin"
hostname="gpmas01rd"
directory="/data1/master/gpseg-1"
repo_host="gpmas01rd"
repo_user="gpadmin"
[restore_segments.0]
user="gpadmin"
hostname="gpseg01rd"
directory="/data1/primary/gpseg0"
repo_host="gpseg01rd"
repo_user="gpadmin"
[restore_segments.1]
user="gpadmin"
hostname="gpseg01rd"
directory="/data1/primary/gpseg1"
repo_host="gpseg01rd"
repo_user="gpadmin"
[restore_segments.2]
user="gpadmin"
hostname="gpseg01rd"
directory="/data1/primary/gpseg2"
repo_host="gpseg01rd"
repo_user="gpadmin"
[restore_segments.3]
user="gpadmin"
hostname="gpseg01rd"
directory="/data1/primary/gpseg3"
repo_host="gpseg01rd"
repo_user="gpadmin"
[restore_segments.4]
user="gpadmin"
hostname="gpseg02rd"
directory="/data1/primary/gpseg4"
repo_host="gpseg02rd"
repo_user="gpadmin"
[restore_segments.5]
user="gpadmin"
hostname="gpseg02rd"
directory="/data1/primary/gpseg5"
repo_host="gpseg02rd"
repo_user="gpadmin"
[restore_segments.6]
user="gpadmin"
hostname="gpseg02rd"
directory="/data1/primary/gpseg6"
repo_host="gpseg02rd"
repo_user="gpadmin"
[restore_segments.7]
user="gpadmin"
hostname="gpseg02rd"
directory="/data1/primary/gpseg7"
repo_host="gpseg02rd"
repo_user="gpadmin"
