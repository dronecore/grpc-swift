/*
 * Copyright 2017, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import Commander
import Dispatch
import Foundation
import gRPC

// Common flags and options
let sslFlag = Flag("ssl", description: "if true, use SSL for connections")
func addressOption(_ address: String) -> Option<String> {
  return Option("address", default: address, description: "address of server")
}

let portOption = Option("port",
                        default: "8081",
                        description: "port of server")
let messageOption = Option("message",
                           default: "Testing 1 2 3",
                           description: "message to send")

// Helper function for client actions
func buildEchoService(_ ssl: Bool, _ address: String, _ port: String, _: String)
  -> Echo_EchoServiceClient {
  var service: Echo_EchoServiceClient
  if ssl {
    let certificateURL = URL(fileURLWithPath: "ssl.crt")
    let certificates = try! String(contentsOf: certificateURL)
    service = Echo_EchoServiceClient(address: address + ":" + port,
                               certificates: certificates,
                               host: "example.com")
    service.host = "example.com"
  } else {
    service = Echo_EchoServiceClient(address: address + ":" + port, secure: false)
  }
  service.metadata = Metadata([
    "x-goog-api-key": "YOUR_API_KEY",
    "x-ios-bundle-identifier": "io.grpc.echo"
  ])
  return service
}

Group {
  $0.command("serve",
             sslFlag,
             addressOption("0.0.0.0"),
             portOption,
             description: "Run an echo server.") { ssl, address, port in
    let sem = DispatchSemaphore(value: 0)
    let echoProvider = EchoProvider()
    if ssl {
      print("starting secure server")
      let certificateURL = URL(fileURLWithPath: "ssl.crt")
      let keyURL = URL(fileURLWithPath: "ssl.key")
      if let echoServer = Echo_EchoServer(address: address + ":" + port,
                                          certificateURL: certificateURL,
                                          keyURL: keyURL,
                                          provider: echoProvider) {
        echoServer.start()
      }
    } else {
      print("starting insecure server")
      let echoServer = Echo_EchoServer(address: address + ":" + port,
                                       provider: echoProvider)
      echoServer.start()
    }
    // This blocks to keep the main thread from finishing while the server runs,
    // but the server never exits. Kill the process to stop it.
    _ = sem.wait(timeout: DispatchTime.distantFuture)
  }

  $0.command("get", sslFlag, addressOption("localhost"), portOption, messageOption,
             description: "Perform a unary get().") { ssl, address, port, message in
    let service = buildEchoService(ssl, address, port, message)
    var requestMessage = Echo_EchoRequest()
    requestMessage.text = message
    print("get sending: " + requestMessage.text)
    let responseMessage = try service.get(requestMessage)
    print("get received: " + responseMessage.text)
  }

  $0.command("expand", sslFlag, addressOption("localhost"), portOption, messageOption,
             description: "Perform a server-streaming expand().") { ssl, address, port, message in
    let service = buildEchoService(ssl, address, port, message)
    var requestMessage = Echo_EchoRequest()
    requestMessage.text = message
    print("expand sending: " + requestMessage.text)
    let sem = DispatchSemaphore(value: 0)
    let expandCall = try service.expand(requestMessage) { result in
      print("expand completed with result \(result)")
      sem.signal()
    }
    var running = true
    while running {
      do {
        let responseMessage = try expandCall.receive()
        print("expand received: \(responseMessage.text)")
      } catch Echo_EchoClientError.endOfStream {
        running = false
      }
    }
    _ = sem.wait(timeout: DispatchTime.distantFuture)
  }

  $0.command("collect", sslFlag, addressOption("localhost"), portOption, messageOption,
             description: "Perform a client-streaming collect().") { ssl, address, port, message in
    let service = buildEchoService(ssl, address, port, message)
    let sem = DispatchSemaphore(value: 0)
    let collectCall = try service.collect { result in
      print("collect completed with result \(result)")
      sem.signal()
    }
    let parts = message.components(separatedBy: " ")
    for part in parts {
      var requestMessage = Echo_EchoRequest()
      requestMessage.text = part
      print("collect sending: " + part)
      try collectCall.send(requestMessage) { error in print(error) }
      sleep(1)
    }
    let responseMessage = try collectCall.closeAndReceive()
    print("collect received: \(responseMessage.text)")
    _ = sem.wait(timeout: DispatchTime.distantFuture)
  }

  $0.command("update", sslFlag, addressOption("localhost"), portOption, messageOption,
             description: "Perform a bidirectional-streaming update().") { ssl, address, port, message in
    let service = buildEchoService(ssl, address, port, message)
    let sem = DispatchSemaphore(value: 0)
    let updateCall = try service.update { result in
      print("update completed with result \(result)")
      sem.signal()
    }

    DispatchQueue.global().async {
      var running = true
      while running {
        do {
          let responseMessage = try updateCall.receive()
          print("update received: \(responseMessage.text)")
        } catch Echo_EchoClientError.endOfStream {
          running = false
        } catch (let error) {
          print("error: \(error)")
        }
      }
    }
    let parts = message.components(separatedBy: " ")
    for part in parts {
      var requestMessage = Echo_EchoRequest()
      requestMessage.text = part
      print("update sending: " + requestMessage.text)
      try updateCall.send(requestMessage) { error in print(error) }
      sleep(1)
    }
    try updateCall.closeSend()
    _ = sem.wait(timeout: DispatchTime.distantFuture)
  }

}.run()
