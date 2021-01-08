import Foundation
import lwip

/**
 The delegate that developer should implement to handle various TCP events.
 */
public protocol TSTCPSocketDelegate: class {
    /**
     The socket is closed on tx side (FIN received). We will not read any data.
     */
    func localDidClose(_ socket: TSTCPSocket)
    
    /**
     The socket is reseted (RST received), it should be released immediately.
     */
    func socketDidReset(_ socket: TSTCPSocket)
    
    /**
     The socket is aborted (RST sent), it should be released immediately.
     */
    func socketDidAbort(_ socket: TSTCPSocket)
    
    /**
     The socket is closed. This will only be triggered if the socket is closed actively by calling `close()`. It should be released immediately.
     */
    func socketDidClose(_ socket: TSTCPSocket)
    
    
    /**
     Socket read data from local tx side.
     
     - parameter data: The read data.
     - parameter from: The socket object.
     */
    func didReadData(_ data: Data, from: TSTCPSocket)
    
    /**
     The socket has sent the specific length of data.
     
     - parameter length: The length of data being ACKed.
     - parameter from:   The socket.
     */
    func didWriteData(_ length: Int, from: TSTCPSocket)
}

// There is no way the error will be anything but ERR_OK, so the `error` parameter should be ignored.
func tcp_recv_func(_ arg: UnsafeMutableRawPointer?, pcb: UnsafeMutablePointer<tcp_pcb>?, buf: UnsafeMutablePointer<pbuf>?, error: err_t) -> err_t {
    assert(error == err_t(ERR_OK))
    
    assert(arg != nil)
    
    guard let socket = SocketDict.lookup(arg!) else {
        // we do not know what this socket is, abort it
        tcp_abort(pcb!)
        return err_t(ERR_ABRT)
    }
    socket.recved(buf)
    return err_t(ERR_OK)
}

func tcp_sent_func(_ arg: UnsafeMutableRawPointer?, pcb: UnsafeMutablePointer<tcp_pcb>?, len: UInt16) -> err_t {
    assert(arg != nil)
    
    guard let socket = SocketDict.lookup(arg!) else {
        // we do not know what this socket is, abort it
        tcp_abort(pcb!)
        return err_t(ERR_ABRT)
    }
    socket.sent(Int(len))
    return err_t(ERR_OK)
}

func tcp_err_func(_ arg: UnsafeMutableRawPointer?, error: err_t) {
    assert(arg != nil)
    
    SocketDict.lookup(arg!)?.errored(error)
}

struct SocketDict {
    static var socketDict: [Int:TSTCPSocket] = [:]
    
    static func lookup(_ id: Int) -> TSTCPSocket? {
        return socketDict[id]
    }
    
    static func lookup(_ arg: UnsafeMutableRawPointer) -> TSTCPSocket? {
        return SocketDict.lookup(arg.bindMemory(to: Int.self, capacity: 1).pointee)
    }
    
    static func newKey() -> Int {
        var key = arc4random()
        while let _ = socketDict[Int(key)] {
            key = arc4random()
        }
        
        return Int(key)
    }
}

/**
 The TCP socket class.
 
 - note: Unless one of `socketDidReset(_:)`, `socketDidAbort(_:)` or `socketDidClose(_:)` delegation methods is called, please do `close()`the socket actively and wait for `socketDidClose(_:)` before releasing it.
 - note: This class is NOT thread-safe, make sure every method call is on the same dispatch queue as `TSIPStack`.
 */
public final class TSTCPSocket {
    fileprivate var pcb: UnsafeMutablePointer<tcp_pcb>?
    /// The source IPv4 address.
    public let sourceAddress: in_addr
    /// The destination IPv4 address
    public let destinationAddress: in_addr
    /// The source port.
    public let sourcePort: UInt16
    /// The destination port.
    public let destinationPort: UInt16
    
    fileprivate var identity: Int
    fileprivate let identityArg: UnsafeMutablePointer<Int>
    fileprivate var closedSignalSend = false
       
//        let cacheQueue = DispatchQueue(label: "TCP Data Write", qos: .userInitiated)
        var queue:DispatchQueue?
        var cache: UnsafeMutablePointer<SliceCache>?
//        fileprivate  static var DataCache: [Int:Data] = [:]
//        fileprivate    var writeLock = NSLock()
//        fileprivate var writeSig = DispatchSemaphore(value: 0)
        
        let printPointer : @convention(c) (UnsafeMutablePointer<Int8>?)->Void = { (data) in
                guard let ss = data else {
                        return
                }
                let str = String(cString: ss)
                NSLog("--------->\(str)")
        }
        
    var isValid: Bool {
        return pcb != nil
    }
    
    /// Whether the socket is connected (we can receive and send data).
    public var isConnected: Bool {
        return isValid && pcb!.pointee.state != CLOSED
    }
    
    /**
     The delegate that handles various TCP events.
     
     - warning: This should be set immediately when developer gets an instance of TSTCPSocket from `didAcceptTCPSocket(_:)` on the same thread that calls it. Simply say, just set it when you get an instance of TSTCPSocket.
     */
    public weak var delegate: TSTCPSocketDelegate?
    
    init(pcb: UnsafeMutablePointer<tcp_pcb>, queue: DispatchQueue) {
        self.pcb = pcb
        
        // see comments in "lwip/src/core/ipv4/ip.c"
        sourcePort = pcb.pointee.remote_port
        destinationPort = pcb.pointee.local_port
        sourceAddress = in_addr(s_addr: pcb.pointee.remote_ip.addr)
        destinationAddress = in_addr(s_addr: pcb.pointee.local_ip.addr)
        
        identity = SocketDict.newKey()
        identityArg = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        identityArg.pointee = identity
        SocketDict.socketDict[identity] = self
        
//        TSTCPSocket.DataCache[identity] = Data()
        
        tcp_arg(pcb, identityArg)
        tcp_recv(pcb, tcp_recv_func)
        tcp_sent(pcb, tcp_sent_func)
        tcp_err(pcb, tcp_err_func)
        
        self.cache = tcp_new_cache()
        self.queue = queue
    }
    
    func errored(_ error: err_t) {
        release()
        switch Int32(error) {
        case ERR_RST:
            delegate?.socketDidReset(self)
        case ERR_ABRT:
            delegate?.socketDidAbort(self)
        default:
            break
        }
    }
    func recved(_ buf: UnsafeMutablePointer<pbuf>?) {
        if buf == nil {
            delegate?.localDidClose(self)
        } else {
            let data = NSMutableData(length: Int((buf?.pointee.tot_len)!))!
            pbuf_copy_partial(buf, data.mutableBytes, (buf?.pointee.tot_len)!, 0)
            delegate?.didReadData(data as Data, from: self)
            if isValid {
                tcp_recved(pcb, (buf?.pointee.tot_len)!)
            }
            pbuf_free(buf)
        }
    }
    
    /**
     Send data to local rx side.
     
     - parameter data: The data to send.
     */
        
        func sent(_ length: Int) {
//                NSLog("--------->[2]sent success len=[\(length)]")
                delegate?.didWriteData(length, from: self)
                let cache_size = tcp_cache_size(self.cache)
                if cache_size == 0{
//                        NSLog("--------->[4]cached is clear")
                        return
                }
                
                NSLog("--------->[3]cache_size is [\(cache_size)]]")
                queue?.async {
                        tcp_pop_data(self.cache, self.pcb, self.printPointer)
                }
                
//                var buf_size = Int(writeBufSize())
//                if buf_size == 0{
//                        NSLog("--------->sent success can't be zero buffer")
//                        return
//                }
//                tcp_pop_data(self.cache, (data as NSData).bytes, buf_size)
//                guard var cache = TSTCPSocket.DataCache[identity] else{
//                        NSLog("--------->NO SUCH CACHE")
//                        return
//                }
//
//                if buf_size > 65536/2{
//                        buf_size = 65536/2
//                }
//
//                let slice = cache.prefix(buf_size)
//                let slice_size = slice.count
//                NSLog("--------->cached size:[\(cache_size)] slice size:[\(slice_size)]")
//                let wRet = tcpWrite(slice)
//                if wRet != ERR_OK{
//                        NSLog("--------->tcp send split err \(wRet)")
//                        self.writeLock.unlock()
//                        return
//                }
//
//                self.writeLock.lock()
//                cache.removeSubrange(0 ..< slice_size)
//                self.writeLock.unlock()
        }
        
//        func appendData(data:Data){
//                self.writeLock.lock()
//                TSTCPSocket.DataCache[identity]?.append(data)
//                self.writeLock.unlock()
//                NSLog("--------->DataCache.count=[\(TSTCPSocket.DataCache.count)] current cache size =[\(TSTCPSocket.DataCache[identity]!.count)]")
//        }
//        
        public func writeBufSize() -> UInt16{
                if pcb == nil{
                        return 0
                }
                return tcp_buf(pcb)
        }
        
        func tcpWrite(_ data: Data) -> err_t{
               
//                NSLog("--------->[1]tcpWrite start to send len=[\(data.count)]")
                let err = tcp_write(pcb, (data as NSData).bytes, UInt16(data.count), UInt8(TCP_WRITE_FLAG_COPY), printPointer )
                if  err != err_t(ERR_OK) {
                        NSLog("---------> tcp_write err[\(err)]")
                        return err
                }
                
                tcp_output(pcb)
                return err_t(ERR_OK)
        }
        
    public func writeData(_ data: Data) -> err_t{
        
        guard isValid else {
                return err_t(ERR_VAL)
        }
        let buf_size = Int(writeBufSize())
        if buf_size == 0{
                tcp_append_cache(self.cache, (data as NSData).bytes, Int32(data.count), printPointer)
                return err_t(ERR_OK)
        }
        
        let data_size = data.count
        if buf_size >= data_size{
                return tcpWrite(data)
        }
        
        let slice = data.prefix(buf_size)
//        NSLog("--------->writeData====lose data_size = [\(data_size)] buf_size=[\(buf_size)]")
//        return tcpWrite(slice)
        
        let wRet = tcpWrite(slice)
        if wRet != ERR_OK{
                NSLog("--------->writeData split err \(wRet)")
                return err_t(ERR_OK)
        }
        
        let remData = data[buf_size ..< data_size] as NSData
        tcp_append_cache(self.cache, remData.bytes, Int32(remData.count), printPointer)

        NSLog("--------->writeData split data_size[\(data_size)] buf_size[\(buf_size)] ")
        return err_t(ERR_OK)
    }
    
    /**
     Close the socket. The socket should not be read or write again.
     */
    public func close() {
        guard isValid else {
            return
        }
        
        tcp_arg(pcb, nil)
        tcp_recv(pcb, nil)
        tcp_sent(pcb, nil)
        tcp_err(pcb, nil)
        
        assert(tcp_close(pcb)==err_t(ERR_OK))
        
        release()
        // the lwip will handle the following things for us
        delegate?.socketDidClose(self)
    }
    
    /**
     Reset the socket. The socket should not be read or write again.
     */
    public func reset() {
        guard isValid else {
            return
        }
        
        tcp_arg(pcb, nil)
        tcp_recv(pcb, nil)
        tcp_sent(pcb, nil)
        tcp_err(pcb, nil)
        
        tcp_abort(pcb)
        release()
        
        delegate?.socketDidClose(self)
    }
    
    func release() {
        pcb = nil
        identityArg.deinitialize(count: 1)
        identityArg.deallocate()
        SocketDict.socketDict.removeValue(forKey: identity)
        tcp_free_cache(self.cache)
        
//        TSTCPSocket.DataCache[identity]?.removeAll()
//        TSTCPSocket.DataCache.removeValue(forKey: identity)
    }
    
    deinit {
    }
}
