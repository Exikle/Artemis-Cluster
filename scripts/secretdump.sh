# Requirements: kubectl and yq
# This will take every key/value in a secret, base64 decode the value, and dump the result to
# a file named as the key name

# It's like doing the inverse process of creating a secret from file like this:
#
# kubectl create secret generic db-user-pass \
#     --from-file=./username.txt \
#     --from-file=./password.txt

# If you use JQ ( https://jqlang.github.io/jq/ )
SECRET=sops-age NAMESPACE=flux-system
for i in `kubectl -n ${NAMESPACE} get secret ${SECRET} -o json | jq -r '.data | keys | .[]'`
do
  echo "Dumping ${i}"
  kubectl -n ${NAMESPACE} get secret ${SECRET} -o json| jq -r '.data."'${i}'"' | base64 -d > ${i}
done

# If you use Mike Farah's yq ( https://github.com/mikefarah/yq )
# SECRET=credentials-staging NAMESPACE=staging
# for i in `kubectl -n ${NAMESPACE} get secret ${SECRET} -o yaml | yq '.data | keys | .[]'`
# do
#   echo "Dumping ${i}"
#   kubectl -n ${NAMESPACE} get secret ${SECRET} -o yaml| yq -r '.data."'${i}'"' | base64 -d > ${i}
# done

# # If you use Andrey Kislyuk's yq ( https://github.com/kislyuk/yq )
# SECRET=credentials-staging NAMESPACE=staging
# for i in `kubectl -n ${NAMESPACE} get secret ${SECRET} -o yaml | yq -r '.data | keys[]'`
# do
#   echo "Dumping ${i}"
#   kubectl -n ${NAMESPACE} get secret ${SECRET} -o yaml | yq -r '.data."'${i}'"' | base64 -d > ${i}
# done