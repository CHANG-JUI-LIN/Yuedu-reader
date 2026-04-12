#!/bin/bash
grep -n "try?" "yuedu app/Models/Models.swift" | grep -A 20 -B 20 "BookStore"
