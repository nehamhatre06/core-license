 

openssl ecparam -genkey -name prime256v1 -out ca.key

openssl req -x509 -new -key ca.key -days 36135 -out ca.crt -config ca.cnf
openssl ecparam -genkey -name prime256v1 -out server.key
openssl req -new -sha256 -key server.key -out server.csr -subj "/C=IN/ST=Maharashtra/L=Mumbai/O=BARCIndia/OU=IT/CN=broker-core.barcindia.in"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 36134 -sha256 -extfile ca.ini -extensions v3_server
openssl ecparam -genkey -name prime256v1 -out 10021397.key
openssl req -new -sha256 -key 10021397.key -out 10021397.csr -subj "/CN=10021397/OU=meter"
openssl x509 -req -in 10021397.csr -CA ca.crt -CAkey ca.key -CAserial ca.srl -out 10021397.crt -days 36134 -sha256 -extfile 10021397.ini -extensions v3_client
