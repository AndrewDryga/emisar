// --auth is enabled already; only loopback can create this first administrator.
const admin = db.getSiblingDB("admin");
admin.createUser({
  user: "root",
  pwd: process.env.PACKTEST_ROOT_PASSWORD,
  roles: [{role: "root", db: "admin"}],
});
if (!admin.auth("root", process.env.PACKTEST_ROOT_PASSWORD)) {
  throw new Error("Fixture administrator authentication failed");
}

const packtest = db.getSiblingDB("packtest");

packtest.orders.insertMany([
  {customer: "alice", status: "paid", amount_cents: 1200},
  {customer: "bob", status: "pending", amount_cents: 3400},
  {customer: "carol", status: "paid", amount_cents: 5600},
]);
packtest.orders.createIndex({customer: 1}, {name: "customer_1"});
packtest.orders.createIndex({status: 1}, {name: "status_1"});

packtest.createUser({
  user: "packtest-index-builder",
  pwd: "packtest-index-builder-734a",
  roles: [{role: "readWrite", db: "packtest"}],
});
