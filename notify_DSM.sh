### DISCLAIMER: This is a third party addition to dockcheck - best effort testing.
# Copy/rename this file to notify.sh to enable email notifications on synology DSM
# Modify to your liking - changing SendMailTo and Subject and content.

send_notification() {
Updates=("$@")
UpdToString=$( printf "%s\n" "${Updates[@]}" )
# change this to your usual destination for synology DSM notification emails
SendMailTo=me@mydomain.com
FromHost=$(hostname)

printf "\nSending email notification\n"

ssmtp $SendMailTo << __EOF
From: "$FromHost" <$SendMailTo>
date:$(date -R)
To: <$SendMailTo>
Subject: [diskstation] Some docker containers need to be updated
Content-Type: text/plain; charset=UTF-8; format=flowed
Content-Transfer-Encoding: 7bit

The following docker containers on $FromHost need to be updated:

$UpdToString

 From $FromHost

__EOF
}
