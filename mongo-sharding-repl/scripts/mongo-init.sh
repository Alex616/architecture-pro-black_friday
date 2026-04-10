#!/bin/bash

###
# Инициализируем бд
###

docker compose exec -T configSrv mongosh --port 27017 <<EOF
rs.initiate(
  {
    _id : "config_server",
       configsvr: true,
    members: [
      { _id : 0, host : "configSrv:27017" }
    ]
  }
);
exit();
EOF

docker compose exec -T shard11 mongosh --port 27018 <<EOF
rs.initiate(
    {
      _id : "shard1",
      members: [
        { _id : 0, host : "shard11:27018" },
        { _id : 1, host : "shard12:27019" },
        { _id : 2, host : "shard13:27020" },
      ]
    }
);
exit();
EOF

docker compose exec -T shard21 mongosh --port 27021 <<EOF
rs.initiate(
    {
      _id : "shard2",
      members: [
       { _id : 0, host : "shard21:27021" },
       { _id : 1, host : "shard22:27022" },
       { _id : 2, host : "shard23:27023" },
      ]
    }
);
exit();
EOF

sleep 5

docker compose exec -T mongos_router mongosh --port 27024 <<EOF
sh.addShard("shard1/shard11:27018");
sh.addShard("shard2/shard21:27021");
sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name" : "hashed" } )
exit();
EOF

docker compose exec -T mongos_router mongosh --port 27024 <<EOF
use somedb;
for(var i = 0; i < 1000; i++) db.helloDoc.insertOne({age:i, name:"ly"+i})
exit();
EOF
