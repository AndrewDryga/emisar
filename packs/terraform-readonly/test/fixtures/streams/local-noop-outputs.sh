#!/bin/sh
# Stands in for the CLI via TF_BIN. This is a real `plan -json` stream from a
# LOCAL-execution workspace, de-identified: identifiers are renamed, while every
# action value, message type and count is exactly what Terraform emitted.
#
# It exists because the stream and a saved plan disagree on spelling — the stream
# says "noop" for an unchanged output, a saved plan says "no-op". Matching only
# one made the two projection paths report different outputs for the same plan.
# 13 of the outputs here are unchanged and must be filtered; one is not.
cat <<'STREAM'
{"@level":"info","@message":"Terraform 1.15.8","@module":"terraform.ui","terraform":"1.15.8","type":"version","ui":"1.3"}
{"@level":"info","@module":"terraform.ui","type":"resource_drift","change":{"resource":{"addr":"example_resource.item0","module":"","resource":"example_resource.item0","resource_type":"example_resource","resource_name":"item0","resource_key":null},"action":"update"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item1","module":"","resource":"example_resource.item1","resource_type":"example_resource","resource_name":"item1","resource_key":null},"action":"update"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item0","module":"","resource":"example_resource.item0","resource_type":"example_resource","resource_name":"item0","resource_key":null},"action":"update"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item2","module":"","resource":"example_resource.item2","resource_type":"example_resource","resource_name":"item2","resource_key":null},"action":"read"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item3","module":"","resource":"example_resource.item3","resource_type":"example_resource","resource_name":"item3","resource_key":null},"action":"read"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item4","module":"","resource":"example_resource.item4","resource_type":"example_resource","resource_name":"item4","resource_key":null},"action":"read"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item5","module":"","resource":"example_resource.item5","resource_type":"example_resource","resource_name":"item5","resource_key":null},"action":"replace"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item6","module":"","resource":"example_resource.item6","resource_type":"example_resource","resource_name":"item6","resource_key":null},"action":"replace"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item7","module":"","resource":"example_resource.item7","resource_type":"example_resource","resource_name":"item7","resource_key":null},"action":"replace"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item8","module":"","resource":"example_resource.item8","resource_type":"example_resource","resource_name":"item8","resource_key":null},"action":"replace"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item9","module":"","resource":"example_resource.item9","resource_type":"example_resource","resource_name":"item9","resource_key":null},"action":"replace"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item10","module":"","resource":"example_resource.item10","resource_type":"example_resource","resource_name":"item10","resource_key":null},"action":"replace"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item11","module":"","resource":"example_resource.item11","resource_type":"example_resource","resource_name":"item11","resource_key":null},"action":"update"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item12","module":"","resource":"example_resource.item12","resource_type":"example_resource","resource_name":"item12","resource_key":null},"action":"update"}}
{"@level":"info","@module":"terraform.ui","type":"planned_change","change":{"resource":{"addr":"example_resource.item13","module":"","resource":"example_resource.item13","resource_type":"example_resource","resource_name":"item13","resource_key":null},"action":"update"}}
{"@level":"info","@module":"terraform.ui","type":"change_summary","changes":{"add":6,"change":5,"import":0,"remove":6,"action_invocation":0,"operation":"plan"}}
{"@level":"info","@module":"terraform.ui","type":"outputs","outputs":{"output_0":{"sensitive":false,"action":"noop"},"output_1":{"sensitive":false,"action":"noop"},"output_2":{"sensitive":false,"action":"noop"},"changed_output":{"sensitive":false,"action":"update"},"output_4":{"sensitive":false,"action":"noop"},"output_5":{"sensitive":false,"action":"noop"},"output_6":{"sensitive":true,"action":"noop"},"output_7":{"sensitive":false,"action":"noop"},"output_8":{"sensitive":true,"action":"noop"},"output_9":{"sensitive":false,"action":"noop"},"output_10":{"sensitive":true,"action":"noop"},"output_11":{"sensitive":false,"action":"noop"},"output_12":{"sensitive":false,"action":"noop"},"output_13":{"sensitive":true,"action":"noop"}}}
STREAM
exit 0
