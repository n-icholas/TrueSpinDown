An automated utility designed to transition idle storage disks into a low-power standby state. Optimized for home-lab environments where the system remains powered but storage access is intermittent.

Warning: This script includes comprehensive activity logging for audit purposes. Use on high-I/O or production systems is strictly discouraged, as frequent start/stop cycles can significantly accelerate mechanical wear and lead to permanent hardware failure.

Produces logs in the following format:
2026-03-27 12:30:02 | --------- CHECK START ---------
2026-03-27 12:30:02 | STANDBY | /dev/sda | Drive already sleeping — no action
2026-03-27 12:30:02 | STANDBY | /dev/sdb | Drive already sleeping — no action
2026-03-27 12:30:02 | STANDBY | /dev/sdc | Drive already sleeping — no action
2026-03-27 12:30:02 | --------- CHECK END -----------


This script can be implemented as a cron job to run each hour.  Worth checking logs after a few days to ensure drives stay sleeping.  If drives are constantly needing to be spun down this script is not for you.
