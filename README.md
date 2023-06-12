# Trying microservices in Kubernetes with an API gateway and OPA for fine grained security

## Trying out microservices on a local Kubernetes(K8s) setup. 

### Clone this repo and run the below steps

### 1. Install docker & kubectl

### 2. Setup minikube on your workstation following the operating system steps

Please follow the OS specific steps in https://minikube.sigs.k8s.io/docs/start/ to setup minikube

The below steps were tried on a Dell Precision laptop running Linux Mint 20.1 to run minikube on docker.
```
 curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
 sudo install minikube-linux-amd64 /usr/local/bin/minikube
 minikube start --kubernetes-version=v1.25.0 --cpus=4 --memory=8g
```
At this point we have a functional K8s cluster with 1 node running on the workstation and we can use the Kubernetes command-line tool(kubectl) to interact with the K8s cluster

```
Eg.
kubectl get pods --all-namespaces
kubectl get all --all-namespaces
```

### 3. Source code

This repo includes an echo api that can be built by the following steps. The echo api exposes /echo/:msg/after/:time and API would respond back with the msg after the time interval. For eg. if you want the service to return hello after 50 milliseconds - curl /echo/hello/after/50

**Build the echo API**
```
 cd src/EchoAPI
 docker build --tag echoapi:0.0.1 .
 minikube image load echoapi:0.0.1  //To ensure that the locally created image is available in the minikube environment) //This step will be required only in certain OS
```

The repo also includes a play framework API that invoke the echo API and return the response from echo to the caller. 
The AsyncAPI (Play framework) exposes /play/asyncapi:delaytime and /play/syncapi:delaytime //The delay time is sent to the echo API

These 2 test APIs are configured by default to invoke the echo API in a Kubernetes env after these have been deployed on K8s (steps below). There are 2 other
apis /play/userapi/20 and /play/adminapi/20 which just returns the output as userAPI returns:20 and adminAPI returns:20. We will use these APis for testing RBAC later with OPA

**Build the Sync and Async APIs**
```
 cd ../AsyncAPI
 mvn clean package play2:dist
 docker build --tag asyncapi:0.0.1 .
 minikube image load asyncapi:0.0.1  //To ensure that the locally created image is available in the minikube environment
```

### 4. Deploy the echo & async microservices in kubernetes

```
cd services
kubectl apply -f echo.yaml
kubectl apply -f async.yaml

//These yamls have the K8s definitions for the echo, sync and async api services. Each service is run as a NodePort and can be accessed from outside the K8s cluster
minikube ip //This prints the IP of the minikube node
kubectl get services //This would indicate the port (in the 32000 range) that is assigned for the 3 services

curl minikubeip:nodeport/play/syncapi/20 //This should return hello in the response after 20 milliseconds
curl minikubeip:nodeport/play/asyncapi/20 //This should return hello in the response after 20 milliseconds
```
You can also export the ip to a varible and use that in your curl commands
export mkubeip=$(minikube ip)
curl $mkubeip:serviceport/play/syncapi/20 //The service port is a random port that will get assigned in the 30000 range if we do not specify it in the service yaml.

*At this point we have 2 microservices running in Kubernetes and the async API invoking the echo API using Kubernetes services*

### 5. Setting up Kong in Kubernetes and configuring Kong to route the API calls to the async service that we deployed above.
```
cd apigw
kubectl apply -f postgres.yaml 

Give some time for postgres to start up. This is an ephemeral postgres and the data is not persisted so it meant for testing. Use a postres on VM or managed services for production environment
you can login to the postgres pod at this point and try the following commands to see the postgres is working fine

kubectl exec -it podname /bin/bash
psql -d kong -U kong -W //this would prompt for a password and the default password is 'password'
once in psql prompt, the following commands can be used
\l to list all the databases
\dt to list all the tables

At this point we have a postgres working and there are no tables in the kong database. The tables get created after you run the next step
kubectl apply -f kong.yaml

\dt at this point will show the kong tables
```

Once Kong is up, we should configure Kong to route traffic to async microservice. Follow the below steps to configure kong
```
In the Kong service yaml, we have set the nodeport that should get used and so the below commands will work as is. If you do not set the nodeport in the yaml
it would take a default port in the 30000 range.

Declare the async microservice in Kong and call it asyncapi
curl -i -s -X POST http://$mkubeip:30081/services \
  --data name=asyncapi \
  --data url='http://asyncservice:9000'

Declare a route in the asyncapi kong service and indicate that any request that starts with /asyncapi should be routed to the asyncapi microservice
curl -i -X POST http://$mkubeip:30081/services/asyncapi/routes \
  --data 'paths[]=/asyncapi' \
  --data name=asyncapiroute

In the response from this API, there is an id attribute that gets returned as the route ID. Copy this ID (eg 2589f4d0-acc4-4d48-8f73-97b0f9605d2c) as this is required in the next step

curl $mkubeip:30080/asyncapi/play/syncapi/20
curl $mkubeip:30080/asyncapi/play/asyncapi/20
curl $mkubeip:30080/asyncapi/play/userapi/20
curl $mkubeip:30080/asyncapi/play/adminapi/20

The above calls would send the request to Kong and Kong would route it to the async microservice. This proves that Kong is working as expected and routing requests correctly
We will now configure Kong to check for a jwt token and validate it using the public key that we provide

The apigw folder already includes a private/public keyt that was generated using the below commands. You can generate new keys as well.
openssl genrsa -out private.pem 2048
openssl rsa -in private.pem -outform PEM -pubout -out public.pem

Create a new consumer in Kong called mobileappusers
curl -d "username=mobileappusers&custom_id=mobileappusers" http://$mkubeip:30081/consumers/

Declare the public key for mobileappusers consumer and give the key name as devopsworkshop 
curl -i -X POST http://$mkubeip:30081/consumers/mobileappusers/jwt \
  -F "algorithm=RS256" \
  -F "rsa_public_key=@./public.pem" \
  -F "key=devopsworkshop"

Enable jwt checks on the route that we created above
curl -X POST http://$mkubeip:30081/routes/2589f4d0-acc4-4d48-8f73-97b0f9605d2c/plugins \
  --data "name=jwt"

At this point, we would get unauthorized error if we try the above APIs
curl $mkubeip:30080/asyncapi/play/syncapi/20

Create a jwt with algorithm as RS256 from jwt.io with the following payload and sign with the private key corresponding to the public key that we added for the mobeileappusers consumer

{
  "sub": "1234567890",
  "iss": "devopsworkshop",
  "role": "user",
  "iat": 1686378877,
  "exp": 1749537277
}

In the above payload, you can fine tune the iat (issued at) and exp (expired) and the iss field should include the key name that we configured above

You should now be able to invoke the above APIs with the generated JWT token
curl $mkubeip:30080/asyncapi/play/userapi/20 -H "Authorization:Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwiaXNzIjoiZGV2b3Bzd29ya3Nob3AiLCJyb2xlIjoiYWRtaW4iLCJpYXQiOjE2ODYzMjkyOTcsImV4cCI6MTY4NjQxNjQwOX0.dDLzOSiutjafl4oBDV2ROJS_k1yk34YtTBlQWl7Tst5e45BGnX54hfLB8G4O1sougdyKM9fABb0WDPpaMHtmAIKFkwQvezgciZ0ttfXyU-eNtPAjC7rXgUQziCQR9EPNSzf4z0LyFttger1j3fniL_7yzWkID_2Lih4NuK9GsD5XsfkjuyF34AWjGfRAA3zekH4z2rRupJKCB59MLS-b6h-DpC8AUDHMxbWPxMzK3q6YLzGUJapQxaM3nFx_mDWG1gYmVMohc7njuLHAAUKihjU2H0LPiL_tzKkc5E8tKjhzg7EgExkn85TcZefY8GyNj5hArDMdf8AoPy8JvUdhpw"
```

### 6. Trying OPA for declarative RBAC

With Kong enabled, we are now able to ensure that only valid requests with a JWT are able to invoke our APIs. We also need to have role based access control and here the default Kong plugins are not really the best. Also it would be good to have a more
declarative way of describing the RBAC rules with request body attributes, request path attributes and info in the jwt payload like roles.

OPA allows us to do all of this. Read more about OPA in their URL.

Below are the steps to setup OPA (https://www.openpolicyagent.org/docs/latest/envoy-tutorial-standalone-envoy/ for more details)

```
Navigate to the services folder and kubectl delete -f async.yaml //this it to remove the existing async.yaml service
Compile the policy.rego file using the opa binary downloaded for your OS and then run the generated bundle on docker
docker run --rm --name bundle-server -d -p 8888:80 -v /path/to/the/compiled/rego/bundle:/usr/share/nginx/html:ro nginx:latest
Create a config map from the envoy.yaml kubectl create configmap proxy-config --from-file envoy.yaml
In the asyncwithopa.yaml, update the path to the bundle server in the line which read --set=services.default.url=http://192.168.64.8:8888
Then create the deployment and service by running kubectl apply -f asyncwithopa.yaml
At this point, we have a multi-container pod running with the async microservice, an envoy proxy and an OPA policy engine. There is also an init container
that runs to configure the pod to route all incoming traffic to the 8000 port (where envoy listens). Envoy would route the request to OPA and only forward the request to the async microservice container once the OPA checks pass 

You can check the envoy configuration in envoy.yaml and the deployment & service configuration in asyncwithopa.yaml.

Now you can generate jwt tokens with role as admin and user and only the admin role jwt token would be allowed to invoke the /adminapi endpoint as that is what the policy.rego defines 
curl $mkubeip:30080/asyncapi/play/userapi/20 -H "Authorization:Bearer actualtokengoes here"
curl $mkubeip:30080/asyncapi/play/adminapi/20 -H "Authorization:Bearer actualtokengoes here"

When you invoke the above curl, the request goes to Kong. Kong verifes the jwt token and forwards the request to the async microservice pod. The network rules set in the pod will forward the request to envoy and envoy send the request for OPA checks for invoking the actual service. This way we have taken care of perimter security (Kong) and also fine grained access control) 

```

