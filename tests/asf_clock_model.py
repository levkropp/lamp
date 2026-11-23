"""Test-only codec frame boundaries and ASF millisecond sample placement.

The runtime never imports this model. Codec PCM comes from separate native
files; this module models framing and presentation, not codec synthesis.
"""
import importlib.util,struct
from bisect import bisect_right
from pathlib import Path

def nearest(n,d):return (n+d//2)//d if n>=0 else -((-n+d//2)//d)
def tag(fmt):
 value=struct.unpack_from('<H',fmt)[0]
 return struct.unpack_from('<H',fmt,24)[0] if value==0xfffe else value

def units(fmt,data):
 """(byte start, raw sample start, sample count, bytes) per codec frame."""
 kind=tag(fmt);ch,rate=struct.unpack_from('<HI',fmt,2);align,bits=struct.unpack_from('<HH',fmt,12)
 if kind in [1,3,6,7]:return [(i*align,i,1,align) for i in range(len(data)//align)]
 result=[];at=sample=0
 if kind in [2,0x11,0x61,0x62]:
  header=7*ch if kind==2 else 16 if kind==0x62 else 4*ch
  for at in range(0,len(data),align):
   size=min(align,len(data)-at)
   if size<header:break
   if kind==0x11:
    group_bytes,group_samples={2:(4,16),3:(12,32),4:(4,8),5:(20,32)}[bits];count=1+(size-header)//(ch*group_bytes)*group_samples
   elif kind==2:count=2+(size-header)*2//ch
   elif kind==0x61:count=1+(size-header)*2//ch
   else:count=((size-header)*2//3)*2
   if not count:break
   result.append((at,sample,count,size));sample+=count
  return result
 if kind in [0x50,0x55]:
  spec=importlib.util.spec_from_file_location('asf_mpeg_fixture',Path(__file__).with_name('verify-flv.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
  frames=list(m.mpeg_frames(data))
  for i,(at,sample,_,size) in enumerate(frames):
   h=int.from_bytes(data[at:at+4],'big');version=h>>19&3;layer=4-(h>>17&3);count=384 if layer==1 else 576 if layer==3 and version!=3 else 1152;result.append((at,sample,count,size))
  return result
 if kind==0xff:
  rates=[96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350]
  while at+7<=len(data):
   assert data[at]==255 and data[at+1]&0xf6==0xf0
   size=(data[at+3]&3)<<11|data[at+4]<<3|data[at+5]>>5
   if at+size>len(data):break
   core=rates[data[at+2]>>2&15];assert rate in [core,core*2];count=1024*(rate//core);result.append((at,sample,count,size));sample+=count;at+=size
  return result
 if kind==0x2000:
  rates=[48000,44100,32000];bitrates=[32,40,48,56,64,80,96,112,128,160,192,224,256,320,384,448,512,576,640]
  while at+8<=len(data):
   assert data[at:at+2]==b'\x0b\x77'
   if data[at+5]>>3>10:
    size=2*(((data[at+2]&7)<<8|data[at+3])+1);count=1536 if data[at+4]>>6==3 else 256*[1,2,3,6][data[at+4]>>4&3]
   else:
    fscod=data[at+4]>>6;code=data[at+4]&63;bitrate=bitrates[code//2];size=[bitrate*4,(bitrate*320//147+(code&1))*2,bitrate*6][fscod];count=1536
   if at+size>len(data):break
   result.append((at,sample,count,size));sample+=count;at+=size
  return result
 raise ValueError('Unmodeled ASF format '+hex(kind))

def object_times(frame_units,starts,rate):
 byte_starts=[x[0] for x in frame_units]
 return [nearest(frame_units[max(0,bisect_right(byte_starts,start)-1)][1]*1000,rate) for start in starts]

def placement(frame_units,starts,times,rate,preroll=0,offset100=0):
 byte_starts=[x[0] for x in frame_units];mapping=[];last_owner=-1;last_ns=0;offset=0
 for at,sample,count,size in frame_units:
  owner=bisect_right(starts,at)-1;assert owner>=0
  if owner!=last_owner:
   ns=times[owner]*1000000+offset100*100-preroll*1000000
   covering=max(0,bisect_right(byte_starts,starts[owner])-1);begin,_,duration,span=frame_units[covering]
   if begin<starts[owner]<begin+span:ns+=nearest(duration*1000000000,rate)
   delta=ns-nearest(sample*1000000000,rate)
   if abs(delta-last_ns)>1000000:offset=nearest(ns*rate,1000000000)-sample;last_ns=delta
   last_owner=owner
  for raw in range(sample,sample+count):
   dest=raw+offset
   if dest<0 or dest<len(mapping):continue
   mapping.extend([None]*(dest-len(mapping)));mapping.append(raw)
 return mapping
