const packtest = db.getSiblingDB("packtest");

packtest.orders.insertMany([
  {customer: "alice", status: "paid", amount_cents: 1200},
  {customer: "bob", status: "pending", amount_cents: 3400},
  {customer: "carol", status: "paid", amount_cents: 5600},
]);
packtest.orders.createIndex({customer: 1}, {name: "customer_1"});
packtest.orders.createIndex({status: 1}, {name: "status_1"});
