ThisBuild / scalaVersion := "3.3.4"
ThisBuild / organization := "com.priostack"
ThisBuild / version      := "0.3.0"

lazy val root = (project in file("."))
  .settings(
    name := "priostack-acn",
    description := "Official Scala client for the Priostack Agent Context Network (ACN).",
    // Transport is the JDK's built-in java.net.http client (no dependency); the
    // only third-party dependency is upickle/ujson for JSON parse + build.
    libraryDependencies += "com.lihaoyi" %% "upickle" % "3.3.1",
    scalacOptions ++= Seq("-deprecation", "-feature", "-explain"),
    // The quickstart is the default entry point for `sbt run`.
    Compile / mainClass := Some("com.priostack.acn.examples.Quickstart")
  )
