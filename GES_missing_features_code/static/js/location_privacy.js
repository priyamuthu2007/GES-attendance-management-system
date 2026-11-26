// Call only after explaining the purpose and obtaining the user's action.
function getAttendanceLocation(){return new Promise((resolve,reject)=>{
 if(!navigator.geolocation)return reject(new Error("Geolocation unavailable"));
 navigator.geolocation.getCurrentPosition(p=>resolve({latitude:p.coords.latitude,
 longitude:p.coords.longitude,accuracy:p.coords.accuracy,timestamp:p.timestamp}),
 e=>reject(new Error(e.message)),{enableHighAccuracy:true,timeout:10000,maximumAge:0});
});}