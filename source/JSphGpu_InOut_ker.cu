//HEAD_DSPH
/*
 <DUALSPHYSICS>  Copyright (c) 2016, Dr Jose M. Dominguez et al. (see http://dual.sphysics.org/index.php/developers/). 

 EPHYSLAB Environmental Physics Laboratory, Universidade de Vigo, Ourense, Spain.
 School of Mechanical, Aerospace and Civil Engineering, University of Manchester, Manchester, U.K.

 This file is part of DualSPHysics. 

 DualSPHysics is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or (at your option) any later version. 

 DualSPHysics is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details. 

 You should have received a copy of the GNU General Public License, along with DualSPHysics. If not, see <http://www.gnu.org/licenses/>. 
*/

/// \file JSphGpu_InOut_ker.cu \brief Implements functions and CUDA kernels for InOut feature.

#include "JSphGpu_InOut_ker.h"
#include <cfloat>
#include <math_constants.h>

namespace cusphinout{

#include "FunctionsMath_ker.cu"

//##############################################################################
//# Kernels for inlet/outlet (JSphInOut).
//# Kernels para inlet/outlet (JSphInOut).
//##############################################################################

//------------------------------------------------------------------------------
/// Mark special fluid particles to ignore.
/// Marca las particulas fluidas especiales para ignorar.
//------------------------------------------------------------------------------
__global__ void KerInOutIgnoreFluidDef(unsigned n,typecode cod,typecode codnew,typecode *code)
{
  unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p<n){
    if(code[p]==cod)code[p]=codnew;
  }
}

//==============================================================================
/// Mark special fluid particles to ignore.
/// Marca las particulas fluidas especiales para ignorar.
//==============================================================================
void InOutIgnoreFluidDef(unsigned n,typecode cod,typecode codnew,typecode *code){
  if(n){
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    KerInOutIgnoreFluidDef <<<sgrid,SPHBSIZE>>> (n,cod,codnew,code);
  }
}


//------------------------------------------------------------------------------
/// Returns original position of periodic particle.
//------------------------------------------------------------------------------
__device__ double3 KerInteraction_PosNoPeriodic(double3 posp1)
{
  if(CTE.periactive&1){//-xperi
    if(posp1.x<CTE.maprealposminx)                 { posp1.x-=CTE.xperincx; posp1.y-=CTE.xperincy; posp1.z-=CTE.xperincz; }
    if(posp1.x>CTE.maprealposminx+CTE.maprealsizex){ posp1.x+=CTE.xperincx; posp1.y+=CTE.xperincy; posp1.z+=CTE.xperincz; }
  }
  if(CTE.periactive&2){//-yperi
    if(posp1.y<CTE.maprealposminy)                 { posp1.x-=CTE.yperincx; posp1.y-=CTE.yperincy; posp1.z-=CTE.yperincz; }
    if(posp1.y>CTE.maprealposminy+CTE.maprealsizey){ posp1.x+=CTE.yperincx; posp1.y+=CTE.yperincy; posp1.z+=CTE.yperincz; }
  }
  if(CTE.periactive&4){//-zperi
    if(posp1.z<CTE.maprealposminz)                 { posp1.x-=CTE.zperincx; posp1.y-=CTE.zperincy; posp1.z-=CTE.zperincz; }
    if(posp1.z>CTE.maprealposminz+CTE.maprealsizez){ posp1.x+=CTE.zperincx; posp1.y+=CTE.zperincy; posp1.z+=CTE.zperincz; }
  }
  return(posp1);
}

//------------------------------------------------------------------------------
/// Updates fluid particle position according to current position.
/// Actualizacion de posicion de particulas fluidas segun posicion actual.
//------------------------------------------------------------------------------
template<bool periactive> __global__ void KerUpdatePosFluid(unsigned n,unsigned pini
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code)
{
  unsigned pp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(pp<n){
    unsigned p=pp+pini;
    const typecode rcode=code[p];
    const bool outrhop=(CODE_GetSpecialValue(rcode)==CODE_OUTRHOP);
    cusph::KerUpdatePos<periactive>(posxy[p],posz[p],0,0,0,outrhop,p,posxy,posz,dcell,code);
  }
}

//==============================================================================
/// Updates fluid particle position according to current position.
/// Actualizacion de posicion de particulas fluidas segun posicion actual.
//==============================================================================
void UpdatePosFluid(byte periactive,unsigned n,unsigned pini
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code)
{
  if(n){
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    if(periactive)KerUpdatePosFluid<true>  <<<sgrid,SPHBSIZE>>> (n,pini,posxy,posz,dcell,code);
    else          KerUpdatePosFluid<false> <<<sgrid,SPHBSIZE>>> (n,pini,posxy,posz,dcell,code);
  }
}


//------------------------------------------------------------------------------
/// Create list of fluid particles in inlet/outlet zones and updates code[].
/// Crea lista de particulas fluind en zonas inlet/outlet y actualiza code[].
//------------------------------------------------------------------------------
__global__ void KerInOutCreateList(unsigned n,unsigned pini
  ,byte convertfluidmask,byte nzone,const byte *cfgzone,const float4 *planes
  ,float3 freemin,float3 freemax
  ,const float2 *boxlimit,const double2 *posxy,const double *posz
  ,typecode *code,unsigned *listp)
{
  extern __shared__ unsigned slist[];
  //float *splanes=(float*)(slist+(n+1));
  if(!threadIdx.x)slist[0]=0;
  __syncthreads();
  const unsigned pp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(pp<n){
    const unsigned p=pp+pini;
    const typecode rcode=code[p];
    if(CODE_IsNormal(rcode) || CODE_IsPeriodic(rcode)){//-It includes normal and periodic particles.
      bool select=CODE_IsFluidInout(rcode);//-Particulas ya marcadas como in/out.
      if(!select){//-Particulas no marcadas como in/out.
        const double2 rxy=posxy[p];
        const double rz=posz[p];
        if(rxy.x<=freemin.x || rxy.y<=freemin.y || rz<=freemin.z || rxy.x>=freemax.x || rxy.y>=freemax.y || rz>=freemax.z){
          byte zone=255;
          if(boxlimit!=NULL){
            for(byte cz=0;cz<nzone && zone==255;cz++)if((cfgzone[cz]&convertfluidmask)!=0){
              const float2 xlim=boxlimit[cz];
              const float2 ylim=boxlimit[nzone+cz];
              const float2 zlim=boxlimit[nzone*2+cz];
              if(xlim.x<=rxy.x && rxy.x<=xlim.y && ylim.x<=rxy.y && rxy.y<=ylim.y && zlim.x<=rz && rz<=zlim.y){
                const float4 rpla=planes[cz];
                if((rpla.x*rxy.x+rpla.y*rxy.y+rpla.z*rz+rpla.w)<0)zone=byte(cz);
              }
            }
          }
          else{
            for(byte cz=0;cz<nzone && zone==255;cz++)if((cfgzone[cz]&convertfluidmask)!=0){
              const float4 rpla=planes[cz];
              if((rpla.x*rxy.x+rpla.y*rxy.y+rpla.z*rz+rpla.w)<0)zone=byte(cz);
            }        
          }
          if(zone!=255){
            code[p]=CODE_ToFluidInout(rcode,zone);
            select=true;
          }
        }
      }
      if(select)slist[atomicAdd(slist,1)+1]=p; //-Add particle in the list.
    }
  }
  __syncthreads();
  const unsigned ns=slist[0];
  __syncthreads();
  if(!threadIdx.x && ns)slist[0]=atomicAdd((listp+n),ns);
  __syncthreads();
  if(threadIdx.x<ns){
    const unsigned cp=slist[0]+threadIdx.x;
    listp[cp]=slist[threadIdx.x+1];
  }
}

//==============================================================================
/// Create list of fluid particles in inlet/outlet zones and updates code[].
/// With stable activated reorders perioc list.
///
/// Con stable activado reordena lista de periodicas.
//==============================================================================
unsigned InOutCreateList(bool stable,unsigned n,unsigned pini
  ,byte convertfluidmask,byte nzone,const byte *cfgzone,const float4 *planes
  ,tfloat3 freemin,tfloat3 freemax
  ,const float2 *boxlimit,const double2 *posxy,const double *posz
  ,typecode *code,unsigned *listp)
{
  unsigned count=0;
  if(n){
    //-listp size list initialized to zero.
    //-Inicializa tama�o de lista listp a cero.
    cudaMemset(listp+n,0,sizeof(unsigned));
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    const unsigned smem=(SPHBSIZE+1)*sizeof(unsigned); //-All fluid particles can be in in/out area and one position for counter.
    KerInOutCreateList <<<sgrid,SPHBSIZE,smem>>> (n,pini,convertfluidmask,nzone,cfgzone,planes,Float3(freemin),Float3(freemax),boxlimit,posxy,posz,code,listp);
    cudaMemcpy(&count,listp+n,sizeof(unsigned),cudaMemcpyDeviceToHost);
    //-Reorders list when stable has been activated.
    //-Reordena lista cuando stable esta activado.
    //if(stable && count){ //-Does not affect results.
    //  thrust::device_ptr<unsigned> dev_list(listp);
    //  thrust::sort(dev_list,dev_list+count);
    //}
  }
  return(count);
}


//------------------------------------------------------------------------------
/// Returns velocity according profile configuration (JSphInOutZone::TpVelProfile).
//------------------------------------------------------------------------------
__device__ float KerInOutCalcVel(byte vprof,const float4 &vdata,float posz){
  float vel=0;
  if(vprof==0)vel=vdata.x;  //-PVEL_Constant
  else if(vprof==1){        //-PVEL_Linear
    const float m=vdata.x;
    const float b=vdata.y;
    vel=m*posz+b;
  }
  else if(vprof==2){        //-PVEL_Parabolic
    const float a=vdata.x;
    const float b=vdata.y;
    const float c=vdata.z;
    vel=a*posz*posz+b*posz+c;
  }
  return(vel);
}

//------------------------------------------------------------------------------
/// Updates velocity and rhop of inlet/outlet particles when it is not extrapolated. 
/// Actualiza velocidad y densidad de particulas inlet/outlet cuando no es extrapolada.
//------------------------------------------------------------------------------
__global__ void KerInOutUpdateData(unsigned n,const unsigned *inoutpart
  ,byte izone,byte rmode,byte vmode,byte vprof
  ,float timestep,float zsurf,float4 veldata,float4 veldata2,float3 dirdata
  ,float coefhydro,float rhopzero,float gamma
  ,const typecode *code,const double *posz,float4 *velrhop)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<n){
    const unsigned p=inoutpart[cp];
    if(izone==byte(CODE_GetIzoneFluidInout(code[p]))){
      const double rposz=posz[p];
      float4 rvelrhop=velrhop[p];
      //-Compute rhop value.
      if(rmode==0)rvelrhop.w=rhopzero; //-MRHOP_Constant
      if(rmode==1){                    //-MRHOP_Hydrostatic
        const float depth=float(double(zsurf)-rposz);
        const float rh=1.f+coefhydro*depth;     //rh=1.+rhop0*(-gravity.z)*(Dp*ptdata.GetDepth(p))/vCteB;
        rvelrhop.w=rhopzero*pow(rh,1.f/gamma);  //rhop[id]=rhop0*pow(rh,(1./gamma));
      }
      //-Compute velocity value.
      float vel=0;
      if(vmode==0){      //-MVEL_Fixed
        vel=KerInOutCalcVel(vprof,veldata,float(rposz));
      }
      else if(vmode==1){ //-MVEL_Variable
        const float vel1=KerInOutCalcVel(vprof,veldata,float(rposz));
        const float vel2=KerInOutCalcVel(vprof,veldata2,float(rposz));
        const float time1=veldata.w;
        const float time2=veldata2.w;
        if(timestep<=time1 || time1==time2)vel=vel1;
        else if(timestep>=time2)vel=vel2;
        else vel=(timestep-time1)/(time2-time1)*(vel2-vel1)+vel1;
      }
      if(vmode!=2){      //-MVEL_Extrapolated
        rvelrhop.x=vel*dirdata.x;
        rvelrhop.y=vel*dirdata.y;
        rvelrhop.z=vel*dirdata.z;
      }
      velrhop[p]=rvelrhop;
    }
  }
}

//==============================================================================
/// Updates velocity and rhop of inlet/outlet particles when it is not extrapolated. 
/// Actualiza velocidad y densidad de particulas inlet/outlet cuando no es extrapolada.
//==============================================================================
void InOutUpdateData(unsigned n,const unsigned *inoutpart
  ,byte izone,byte rmode,byte vmode,byte vprof
  ,float timestep,float zsurf,tfloat4 veldata,tfloat4 veldata2,tfloat3 dirdata
  ,float coefhydro,float rhopzero,float gamma
  ,const typecode *code,const double *posz,float4 *velrhop)
{
  if(n){
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    KerInOutUpdateData <<<sgrid,SPHBSIZE>>> (n,inoutpart,izone,rmode,vmode,vprof
      ,timestep,zsurf,Float4(veldata),Float4(veldata2),Float3(dirdata),coefhydro,rhopzero,gamma,code,posz,velrhop);
  }
}


//------------------------------------------------------------------------------
/// Updates velocity and rhop of inlet/outlet particles when it is not extrapolated. 
/// Actualiza velocidad y densidad de particulas inlet/outlet cuando no es extrapolada.
//------------------------------------------------------------------------------
__global__ void KerInoutClearInteractionVars(unsigned n,const int *inoutpart
  ,float3 *ace,float *ar,float *viscdt,float3 *shiftpos)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<n){
    const unsigned p=inoutpart[cp];
    ace[p]=make_float3(0,0,0);
    ar[p]=0;
    viscdt[p]=0;
    if(shiftpos!=NULL)shiftpos[p]=make_float3(0,0,0);
  }
}

//==============================================================================
/// Updates velocity and rhop of inlet/outlet particles when it is not extrapolated. 
/// Actualiza velocidad y densidad de particulas inlet/outlet cuando no es extrapolada.
//==============================================================================
void InoutClearInteractionVars(unsigned n,const int *inoutpart
  ,float3 *ace,float *ar,float *viscdt,float3 *shiftpos)
{
  if(n){
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    KerInoutClearInteractionVars <<<sgrid,SPHBSIZE>>> (n,inoutpart,ace,ar,viscdt,shiftpos);
  }
}


//------------------------------------------------------------------------------
/// Updates velocity and rhop for M1 variable when Verlet is used. 
/// Actualiza velocidad y densidad de varible M1 cuando se usa Verlet.
//------------------------------------------------------------------------------
__global__ void KerInOutUpdateVelrhopM1(unsigned n,const int *inoutpart
  ,const float4 *velrhop,float4 *velrhopm1)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<n){
    const unsigned p=inoutpart[cp];
    velrhopm1[p]=velrhop[p];
  }
}

//==============================================================================
/// Updates velocity and rhop for M1 variable when Verlet is used. 
/// Actualiza velocidad y densidad de varible M1 cuando se usa Verlet.
//==============================================================================
void InOutUpdateVelrhopM1(unsigned n,const int *inoutpart
  ,const float4 *velrhop,float4 *velrhopm1)
{
  if(n){
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    KerInOutUpdateVelrhopM1 <<<sgrid,SPHBSIZE>>> (n,inoutpart,velrhop,velrhopm1);
  }
}


//------------------------------------------------------------------------------
/// Checks particle position.
/// If particle is moved to fluid zone then it changes to fluid particle and 
/// it creates a new in/out particle.
/// If particle is moved out the domain then it changes to ignore particle.
//------------------------------------------------------------------------------
template<bool periactive> __global__ void KerInOutComputeStep(unsigned n,int *inoutpart
  ,double dt,const float4 *planes,const float *width,const float4 *velrhop
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<n){
    const int p=inoutpart[cp];
    //-Checks if particle was moved to fluid domain.
    const typecode rcode=code[p];
    const byte izone=byte(CODE_GetIzoneFluidInout(rcode));
    const double2 rposxy=posxy[p];
    const float displane=-cumath::KerDistPlaneSign(planes[izone],float(rposxy.x),float(rposxy.y),float(posz[p]));
    if(displane<0)inoutpart[cp]=-int(p);//-Particle is moved to fluid domain.  //-It is not necessary on GPU code.
    else if(displane>width[izone]){//-Particle is moved out in/out zone.
      code[p]=CODE_SetOutIgnore(rcode);
      inoutpart[cp]=INT_MAX;  //-It is not necessary on GPU code.
    }
  }
}

//==============================================================================
/// Checks particle position.
/// If particle is moved to fluid zone then it changes to fluid particle and 
/// it creates a new in/out particle.
/// If particle is moved out the domain then it changes to ignore particle.
//==============================================================================
void InOutComputeStep(byte periactive,unsigned n,int *inoutpart
  ,double dt,const float4 *planes,const float *width,const float4 *velrhop
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code)
{
  if(n){
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    if(periactive)KerInOutComputeStep<true>  <<<sgrid,SPHBSIZE>>> (n,inoutpart,dt,planes,width,velrhop,posxy,posz,dcell,code);
    else          KerInOutComputeStep<false> <<<sgrid,SPHBSIZE>>> (n,inoutpart,dt,planes,width,velrhop,posxy,posz,dcell,code);
  }
}


//------------------------------------------------------------------------------
/// Create list for new inlet particles to create.
/// Crea lista de nuevas particulas inlet a crear.
//------------------------------------------------------------------------------
__global__ void KerInOutListCreate(unsigned n,unsigned nmax,int *inoutpart)
{
  extern __shared__ unsigned slist[];
  if(!threadIdx.x)slist[0]=0;
  __syncthreads();
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<n && inoutpart[cp]<0){
    slist[atomicAdd(slist,1)+1]=unsigned(-inoutpart[cp]); //-Add particle in the list.
  }
  __syncthreads();
  const unsigned ns=slist[0];
  __syncthreads();
  if(!threadIdx.x && ns)slist[0]=n + atomicAdd((inoutpart+nmax),ns);
  __syncthreads();
  if(threadIdx.x<ns){
    const unsigned cp2=slist[0]+threadIdx.x;
    if(cp2<nmax)inoutpart[cp2]=slist[threadIdx.x+1];
  }
}

//==============================================================================
/// Create list for new inlet particles to create at end of inoutpart[]. 
/// Returns number of new particles to create.
/// 
/// Crea lista de nuevas particulas inlet a crear al final de inoutpart[].
/// Devuelve el numero de las nuevas particulas para crear.
//==============================================================================
unsigned InOutListCreate(bool stable,unsigned n,unsigned nmax,int *inoutpart)
{
  unsigned count=0;
  if(n){
    //-inoutpart size list initialized to zero.
    //-Inicializa tama�o de lista inoutpart a cero.
    cudaMemset(inoutpart+nmax,0,sizeof(unsigned));
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    const unsigned smem=(SPHBSIZE+1)*sizeof(unsigned); //-All fluid particles can be in in/out area and one position for counter.
    KerInOutListCreate <<<sgrid,SPHBSIZE,smem>>> (n,nmax,inoutpart);
    cudaMemcpy(&count,inoutpart+nmax,sizeof(unsigned),cudaMemcpyDeviceToHost);
    //-Reorders list if it is valid and stable has been activated.
    //-Reordena lista si es valida y stable esta activado.
    if(stable && count && count<=nmax){
      thrust::device_ptr<unsigned> dev_list((unsigned*)inoutpart);
      thrust::sort(dev_list+n,dev_list+n+count);
    }
  }
  return(count);
}


//------------------------------------------------------------------------------
/// Creates new inlet particles to replace the particles moved to fluid domain.
//------------------------------------------------------------------------------
template<bool periactive> __global__ void KerInOutCreateNewInlet(unsigned newn,const unsigned *newinoutpart
  ,unsigned np,unsigned idnext,typecode codenewpart,const float3 *dirdata,const float *width
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code,unsigned *idp,float4 *velrhop)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<newn){
    const int p=newinoutpart[cp];
    const byte izone=byte(CODE_GetIzoneFluidInout(code[p]));
    code[p]=codenewpart;//-Particle changes to fluid particle.
    const double dis=width[izone];
    const float3 rdirdata=dirdata[izone];
    double2 rposxy=posxy[p];
    double rposz=posz[p];
    rposxy.x-=dis*rdirdata.x;
    rposxy.y-=dis*rdirdata.y;
    rposz-=dis*rdirdata.z;
    const unsigned p2=np+cp;
    code[p2]=CODE_ToFluidInout(codenewpart,izone);
    cusph::KerUpdatePos<periactive>(rposxy,rposz,0,0,0,false,p2,posxy,posz,dcell,code);
    idp[p2]=idnext+cp;
    velrhop[p2]=make_float4(0,0,0,0);
  }
}

//==============================================================================
/// Creates new inlet particles to replace the particles moved to fluid domain.
//==============================================================================
void InOutCreateNewInlet(byte periactive,unsigned newn,const unsigned *newinoutpart
  ,unsigned np,unsigned idnext,typecode codenewpart,const float3 *dirdata,const float *width
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code,unsigned *idp,float4 *velrhop)
{
  if(newn){
    dim3 sgrid=cusph::GetGridSize(newn,SPHBSIZE);
    if(periactive)KerInOutCreateNewInlet<true>  <<<sgrid,SPHBSIZE>>> (newn,newinoutpart,np,idnext,codenewpart,dirdata,width,posxy,posz,dcell,code,idp,velrhop);
    else          KerInOutCreateNewInlet<false> <<<sgrid,SPHBSIZE>>> (newn,newinoutpart,np,idnext,codenewpart,dirdata,width,posxy,posz,dcell,code,idp,velrhop);
  }
}


//------------------------------------------------------------------------------
/// Move in/out particles according its velocity.
//------------------------------------------------------------------------------
template<bool periactive> __global__ void KerInOutFillMove(unsigned n,const unsigned *inoutpart
  ,double dt,const float4 *velrhop
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<n){
    const unsigned p=inoutpart[cp];
    //-Updates position of particles.
    const float4 rvelrhop=velrhop[p];
    const double dx=double(rvelrhop.x)*dt;
    const double dy=double(rvelrhop.y)*dt;
    const double dz=double(rvelrhop.z)*dt;
    cusph::KerUpdatePos<periactive>(posxy[p],posz[p],dx,dy,dz,false,p,posxy,posz,dcell,code);
  }
}

//==============================================================================
/// Move particles in/out according its velocity.
//==============================================================================
void InOutFillMove(byte periactive,unsigned n,const unsigned *inoutpart
  ,double dt,const float4 *velrhop
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code)
{
  if(n){
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    if(periactive)KerInOutFillMove<true>  <<<sgrid,SPHBSIZE>>> (n,inoutpart,dt,velrhop,posxy,posz,dcell,code);
    else          KerInOutFillMove<false> <<<sgrid,SPHBSIZE>>> (n,inoutpart,dt,velrhop,posxy,posz,dcell,code);
  }
}


//------------------------------------------------------------------------------
/// Computes projection data to filling mode.
//------------------------------------------------------------------------------
__global__ void KerInOutFillProjection(unsigned n,const unsigned *inoutpart
  ,typecode codenewpart,const float4 *planes,const float *width
  ,const double2 *posxy,const double *posz
  ,typecode *code,float *prodist,double2 *proposxy,double *proposz)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<n){
    const unsigned p=inoutpart[cp];
    //-Checks if particle was moved to fluid domain.
    const typecode rcode=code[p];
    const byte izone=byte(CODE_GetIzoneFluidInout(rcode));
    const double2 rposxy=posxy[p];
    const double rposz=posz[p];
    const float4 rplanes=planes[izone];
    //-Compute distance to plane.
    const double v1=(rposxy.x*rplanes.x + rposxy.y*rplanes.y + rposz*rplanes.z + rplanes.w);
    const float v2=rplanes.x*rplanes.x+rplanes.y*rplanes.y+rplanes.z*rplanes.z;
    const float displane=-float(v1/sqrt(v2));//-Equivalent to fgeo::PlaneDistSign().
    //-Calculates point on plane and distance.
    float rprodis=0;
    double rpropx=0,rpropy=0,rpropz=0;
    if(displane<0 || displane>width[izone]){
      code[p]=(displane<0? codenewpart: CODE_SetOutIgnore(rcode));
      //-if (displane<0) Particle changes to fluid particle.
      //-if (displane>Width[izone]) Particle is moved out in/out zone.
    }
    else{
      rprodis=displane; //=fabs(displane); No hace falta porque siempre es positivo cuando ok=true.
      //-Equivalent to fmath::PtOrthogonal().
      const double t=-v1/v2;
      rpropx=rposxy.x+t*rplanes.x;
      rpropy=rposxy.y+t*rplanes.y;
      rpropz=rposz+t*rplanes.z;
    }
    //-Saves results on GPU memory.
    prodist[cp]=rprodis;
    proposxy[cp]=make_double2(rpropx,rpropy);
    proposz[cp] =rpropz;
  }
}

//==============================================================================
/// Computes projection data to filling mode.
//==============================================================================
void InOutFillProjection(unsigned n,const unsigned *inoutpart
  ,typecode codenewpart,const float4 *planes,const float *width
  ,const double2 *posxy,const double *posz
  ,typecode *code,float *prodist,double2 *proposxy,double *proposz)
{
  if(n){
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    KerInOutFillProjection <<<sgrid,SPHBSIZE>>> (n,inoutpart,codenewpart,planes,width,posxy,posz,code,prodist,proposxy,proposz);
  }
}


//------------------------------------------------------------------------------
/// Removes particles above the Zsurf limit.
//------------------------------------------------------------------------------
__global__ void KerInOutRemoveZsurf(unsigned n,const unsigned *inoutpart
  ,typecode codezone,float zsurf,const double *posz
  ,typecode *code,float *prodist,double2 *proposxy,double *proposz)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<n){
    const unsigned p=inoutpart[cp];
    if(code[p]==codezone && posz[p]>zsurf){
      code[p]=CODE_SetOutIgnore(code[p]);
      prodist[cp]=0;
      proposxy[cp]=make_double2(0,0);
      proposz[cp]=0;
    }
  }
}

//==============================================================================
/// Removes particles above the Zsurf limit.
//==============================================================================
void InOutRemoveZsurf(unsigned n,const unsigned *inoutpart
  ,typecode codezone,float zsurf,const double *posz
  ,typecode *code,float *prodist,double2 *proposxy,double *proposz)
{
  if(n){
    dim3 sgrid=cusph::GetGridSize(n,SPHBSIZE);
    KerInOutRemoveZsurf <<<sgrid,SPHBSIZE>>> (n,inoutpart,codezone,zsurf,posz,code,prodist,proposxy,proposz);
  }
}


//------------------------------------------------------------------------------
/// Compute maximum distance to create points in each PtPos.
/// Create list of selected ptpoints and its distance for new inlet/outlet particles.
//------------------------------------------------------------------------------
__global__ void KerInOutFillListCreate(unsigned npt
  ,const double2 *ptposxy,const double *ptposz
  ,const byte *ptzone,const float *zsurf,const float *width
  ,unsigned npropt,const float *prodist,const double2 *proposxy,const double *proposz
  ,float dpmin,float dpmin2,float dp,float *ptdist,unsigned nmax,unsigned *inoutpart)
{
  extern __shared__ unsigned slist[];
  //float *sdist=(float*)(slist+(blockDim.x+1));
  if(!threadIdx.x)slist[0]=0;
  __syncthreads();
  const unsigned cpt=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cpt<npt){
    const double2 rptxy=ptposxy[cpt];
    const double rptz=ptposz[cpt];
    float distmax=FLT_MAX;
    if(zsurf==NULL || float(rptz)<=zsurf[ptzone[cpt]]){
      distmax=0;
      for(int cpro=0;cpro<npropt;cpro++){
        const double2 propsxy=proposxy[cpro];
        const float disx=rptxy.x-propsxy.x;
        const float disy=rptxy.y-propsxy.y;
        const float disz=rptz   -proposz [cpro];
        if(disx<=dpmin && disy<=dpmin && disz<=dpmin){//-particle near to ptpoint (approx.)
          const float dist2=(disx*disx+disy*disy+disz*disz);
          if(dist2<dpmin2){//-particle near to ptpoint.
            const float dmax=prodist[cpro]+sqrt(dpmin2-dist2);
            distmax=max(distmax,dmax);
          }
        }
      }
    }
    distmax=(distmax==0? dp: distmax);
    //-Creates list of new inlet/outlet particles.
    if(distmax<width[ptzone[cpt]]){
      slist[atomicAdd(slist,1)+1]=cpt; //-Add ptpoint in the list.
      ptdist[cpt]=distmax;             //-Saves distance of ptpoint.
    }
  }
  __syncthreads();
  const unsigned ns=slist[0];
  __syncthreads();
  if(!threadIdx.x && ns)slist[0]=atomicAdd((inoutpart+nmax),ns);
  __syncthreads();
  if(threadIdx.x<ns){
    const unsigned cp2=slist[0]+threadIdx.x;
    if(cp2<nmax)inoutpart[cp2]=slist[threadIdx.x+1];
  }
}

//==============================================================================
/// Compute maximum distance to create points in each PtPos.
/// Create list of selected ptpoints and its distance for new inlet/outlet particles.
/// Returns number of new particles to create.
//==============================================================================
unsigned InOutFillListCreate(bool stable,unsigned npt
  ,const double2 *ptposxy,const double *ptposz
  ,const byte *ptzone,const float *zsurf,const float *width
  ,unsigned npropt,const float *prodist,const double2 *proposxy,const double *proposz
  ,float dpmin,float dpmin2,float dp,float *ptdist,unsigned nmax,unsigned *inoutpart)
{
  unsigned count=0;
  if(npt){
    //-inoutpart size list initialized to zero.
    //-Inicializa tama�o de lista inoutpart a cero.
    cudaMemset(inoutpart+nmax,0,sizeof(unsigned));
    dim3 sgrid=cusph::GetGridSize(npt,SPHBSIZE);
    const unsigned smem=(SPHBSIZE+1)*sizeof(unsigned); //-All fluid particles can be in in/out area and one position for counter.
    KerInOutFillListCreate <<<sgrid,SPHBSIZE,smem>>> (npt,ptposxy,ptposz,ptzone,zsurf,width,npropt,prodist,proposxy,proposz,dpmin,dpmin2,dp,ptdist,nmax,inoutpart);
    cudaMemcpy(&count,inoutpart+nmax,sizeof(unsigned),cudaMemcpyDeviceToHost);
    //-Reorders list if it is valid and stable has been activated.
    //-Reordena lista si es valida y stable esta activado.
    if(stable && count && count<=nmax){
      thrust::device_ptr<unsigned> dev_list((unsigned*)inoutpart);
      thrust::sort(dev_list,dev_list+count);
    }
  }
  return(count);
}


//------------------------------------------------------------------------------
/// Creates new inlet/outlet particles to fill inlet/outlet domain.
//------------------------------------------------------------------------------
template<bool periactive> __global__ void KerInOutFillCreate(unsigned newn,const unsigned *newinoutpart
  ,const double2 *ptposxy,const double *ptposz,const byte *ptzone,const float *ptauxdist
  ,unsigned np,unsigned idnext,typecode codenewpart,const float3 *dirdata
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code,unsigned *idp,float4 *velrhop)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<newn){
    const unsigned cpt=newinoutpart[cp];
    const byte izone=ptzone[cpt];
    const double dis=ptauxdist[cpt];
    const float3 rdirdata=dirdata[izone];
    double2 rposxy=ptposxy[cpt];
    double rposz=ptposz[cpt];
    rposxy.x-=dis*rdirdata.x;
    rposxy.y-=dis*rdirdata.y;
    rposz   -=dis*rdirdata.z;
    const unsigned p=np+cp;
    code[p]=CODE_ToFluidInout(codenewpart,izone);
    cusph::KerUpdatePos<periactive>(rposxy,rposz,0,0,0,false,p,posxy,posz,dcell,code);
    idp[p]=idnext+cp;
    velrhop[p]=make_float4(0,0,0,0);
  }
}

//==============================================================================
/// Creates new inlet/outlet particles to fill inlet/outlet domain.
//==============================================================================
void InOutFillCreate(byte periactive,unsigned newn,const unsigned *newinoutpart
  ,const double2 *ptposxy,const double *ptposz,const byte *ptzone,const float *ptauxdist
  ,unsigned np,unsigned idnext,typecode codenewpart,const float3 *dirdata
  ,double2 *posxy,double *posz,unsigned *dcell,typecode *code,unsigned *idp,float4 *velrhop)
{
  if(newn){
    dim3 sgrid=cusph::GetGridSize(newn,SPHBSIZE);
    if(periactive)KerInOutFillCreate<true>  <<<sgrid,SPHBSIZE>>> (newn,newinoutpart,ptposxy,ptposz,ptzone,ptauxdist,np,idnext,codenewpart,dirdata,posxy,posz,dcell,code,idp,velrhop);
    else          KerInOutFillCreate<false> <<<sgrid,SPHBSIZE>>> (newn,newinoutpart,ptposxy,ptposz,ptzone,ptauxdist,np,idnext,codenewpart,dirdata,posxy,posz,dcell,code,idp,velrhop);
  }
}


//------------------------------------------------------------------------------
/// Calculates maximum zsurf in fluid domain.
//------------------------------------------------------------------------------
template<unsigned blockSize> __global__ void KerInOutComputeZsurf
  (unsigned nptz,const float3 *ptzpos,float maxdist2,float zbottom
  ,int hdiv,int4 nc,unsigned cellfluid,const int2 *begincell,int3 cellzero
  ,const double2 *posxy,const double *posz,const typecode *code,float *res)
{
  extern __shared__ float sfdat[];
  const unsigned tid=threadIdx.x;

  const unsigned p1=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p1<nptz){
    float zsurfmax=zbottom;
    //-Obtains basic data of particle p1.
    const float3 posp1=ptzpos[p1];
    
    //-Obtains interaction limits.
    int cxini,cxfin,yini,yfin,zini,zfin;
    cusph::KerGetInteractionCells(posp1.x,posp1.y,posp1.z,hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

    //-Interaction with fluids.
    for(int z=zini;z<zfin;z++){
      int zmod=(nc.w)*z+cellfluid; //-The sum showing where fluid cells start. | Le suma donde empiezan las celdas de fluido.
      for(int y=yini;y<yfin;y++){
        int ymod=zmod+nc.x*y;
        unsigned pini,pfin=0;
        for(int x=cxini;x<cxfin;x++){
          int2 cbeg=begincell[x+ymod];
          if(cbeg.y){
            if(!pfin)pini=cbeg.x;
            pfin=cbeg.y;
          }
        }
        if(pfin)for(int p2=pini;p2<pfin;p2++){
          const float poszp2=float(posz[p2]);
          if(poszp2>zsurfmax){
            const float drz=posp1.z-poszp2;
            const double2 posxyp2=posxy[p2];
            const float drx=posp1.x-float(posxyp2.x);
            const float dry=posp1.y-float(posxyp2.y);
            const float rr2=drx*drx+dry*dry+drz*drz;
            if(rr2<=maxdist2 && CODE_IsFluidNotInout(code[p2]))zsurfmax=poszp2;//-Only with fluid particles but not inout particles.
          }
        }
      }
    }
    sfdat[tid]=zsurfmax;
  }
  else sfdat[tid]=zbottom;
  //-Reduces maximum in shared memory.
  __syncthreads();
  if(blockSize>=512){ if(tid<256)sfdat[tid]=max(sfdat[tid],sfdat[tid+256]);  __syncthreads(); }
  if(blockSize>=256){ if(tid<128)sfdat[tid]=max(sfdat[tid],sfdat[tid+128]);  __syncthreads(); }
  if(blockSize>=128){ if(tid<64) sfdat[tid]=max(sfdat[tid],sfdat[tid+64] );  __syncthreads(); }
  if(tid<32)cusph::KerReduMaxFloatWarp<blockSize>(sfdat,tid);
  if(tid==0)res[blockIdx.y*gridDim.x + blockIdx.x]=sfdat[0];
}

//==============================================================================
/// Calculates maximum zsurf in fluid domain.
//==============================================================================
float InOutComputeZsurf(unsigned nptz,const float3 *ptzpos,float maxdist,float zbottom
  ,TpCellMode cellmode,tuint3 ncells,const int2 *begincell,tuint3 cellmin
  ,const double2 *posxy,const double *posz,const typecode *code
  ,float *auxg,float *auxh)
{
  const int hdiv=(cellmode==CELLMODE_H? 2: 1);
  const int4 nc=make_int4(int(ncells.x),int(ncells.y),int(ncells.z),int(ncells.x*ncells.y));
  const unsigned cellfluid=nc.w*nc.z+1;
  const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
  float zsurfmax=zbottom;
  if(nptz){
    const unsigned bsize=256;
    dim3 sgrid=cusph::GetGridSize(nptz,bsize);
    unsigned smem=sizeof(float)*bsize;
    KerInOutComputeZsurf<bsize> <<<sgrid,bsize,smem>>> (nptz,ptzpos,(maxdist*maxdist),zbottom,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,auxg);
    const unsigned nblocks=sgrid.x*sgrid.y;
    cudaMemcpy(auxh,auxg,sizeof(float)*nblocks,cudaMemcpyDeviceToHost);
    for(unsigned c=0;c<nblocks;c++)zsurfmax=max(zsurfmax,auxh[c]);
  }
  return(zsurfmax);
}


//------------------------------------------------------------------------------
/// Perform interaction between ghost inlet/outlet nodes and fluid particles. GhostNodes-Fluid
/// Realiza interaccion entre ghost inlet/outlet nodes y particulas de fluido. GhostNodes-Fluid
//------------------------------------------------------------------------------
template<bool sim2d,TpKernel tker> __global__ void KerInteractionInOutExtrap_Double
  (unsigned inoutcount,const int *inoutpart,const byte *cfgzone,byte computerhopmask,byte computevelmask
  ,const float4 *planes,const float* width,const float3 *dirdata,float determlimit
  ,int hdiv,int4 nc,unsigned cellfluid,const int2 *begincell,int3 cellzero
  ,const double2 *posxy,const double *posz,const typecode *code,const unsigned *idp
  ,float4 *velrhop)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<inoutcount){
    const unsigned p1=inoutpart[cp];
    const byte izone=byte(CODE_GetIzoneFluidInout(code[p1]));
    const byte cfg=cfgzone[izone];
    const bool computerhop=((cfg&computerhopmask)!=0);
    const bool computevel= ((cfg&computevelmask )!=0);
    if(computerhop || computevel){
      //-Calculates ghost node position.
      double3 pos_p1=make_double3(posxy[p1].x,posxy[p1].y,posz[p1]);
      if(CODE_IsPeriodic(code[p1]))pos_p1=KerInteraction_PosNoPeriodic(pos_p1);
      const double displane=cumath::DistPlane(planes[izone],pos_p1)*2;
      const float3 rdirdata=dirdata[izone];
      const double3 posp1=make_double3(pos_p1.x+displane*rdirdata.x, pos_p1.y+displane*rdirdata.y, pos_p1.z+displane*rdirdata.z); //-Ghost node position.

      //-Initializes variables for calculation.
      double rhopp1=0;
      double3 gradrhopp1=make_double3(0,0,0);
      double3 velp1=make_double3(0,0,0);
      tmatrix3d gradvelp1; cumath::Tmatrix3dReset(gradvelp1); //-Only for velocity.
      tmatrix3d a_corr2; if(sim2d) cumath::Tmatrix3dReset(a_corr2); //-Only for 2D.
      tmatrix4d a_corr3; if(!sim2d)cumath::Tmatrix4dReset(a_corr3); //-Only for 3D.

      //-Obtains interaction limits.
      int cxini,cxfin,yini,yfin,zini,zfin;
      cusph::KerGetInteractionCells(posp1.x,posp1.y,posp1.z,hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

      //-Interaction with fluids.
      for(int z=zini;z<zfin;z++){
        int zmod=(nc.w)*z+cellfluid; //-The sum showing where fluid cells start. | Le suma donde empiezan las celdas de fluido.
        for(int y=yini;y<yfin;y++){
          int ymod=zmod+nc.x*y;
          unsigned pini,pfin=0;
          for(int x=cxini;x<cxfin;x++){
            int2 cbeg=begincell[x+ymod];
            if(cbeg.y){
              if(!pfin)pini=cbeg.x;
              pfin=cbeg.y;
            }
          }
          if(pfin)for(unsigned p2=pini;p2<pfin;p2++){
            const double2 p2xy=posxy[p2];
            const double drx=double(posp1.x-p2xy.x);
            const double dry=double(posp1.y-p2xy.y);
            const double drz=double(posp1.z-posz[p2]);
            const double rr2=drx*drx+dry*dry+drz*drz;
            if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO && CODE_IsFluidNotInout(code[p2])){//-Only with fluid particles but not inout particles.
              //-Wendland or Cubic Spline kernel.
			  float ffrx,ffry,ffrz,fwab;
			  if(tker==KERNEL_Wendland)cusph::KerGetKernelWendland(float(rr2),float(drx),float(dry),float(drz),ffrx,ffry,ffrz,fwab);
			  else if(tker==KERNEL_Cubic)cusph::KerGetKernelCubic(float(rr2),float(drx),float(dry),float(drz),ffrx,ffry,ffrz,fwab);
  		      const double frx=ffrx,fry=ffry,frz=ffrz,wab=fwab;

              const float4 velrhopp2=velrhop[p2];
              //===== Get mass and volume of particle p2 =====
              double massp2=CTE.massf;
              double volp2=massp2/velrhopp2.w;

              //===== Density and its gradient =====
              rhopp1+=massp2*wab;
              gradrhopp1.x+=massp2*frx;
              gradrhopp1.y+=massp2*fry;
              gradrhopp1.z+=massp2*frz;

              //===== Kernel values multiplied by volume =====
              const double vwab=wab*volp2;
              const double vfrx=frx*volp2;
              const double vfry=fry*volp2;
              const double vfrz=frz*volp2;

              //===== Velocity and its gradient =====
              if(computevel){
                velp1.x+=vwab*velrhopp2.x;
                velp1.y+=vwab*velrhopp2.y;
                velp1.z+=vwab*velrhopp2.z;
                gradvelp1.a11+=vfrx*velrhopp2.x;	// du/dx
                gradvelp1.a12+=vfry*velrhopp2.x;	// du/dy
                gradvelp1.a13+=vfrz*velrhopp2.x;	// du/dz
                gradvelp1.a21+=vfrx*velrhopp2.y;	// dv/dx
                gradvelp1.a22+=vfry*velrhopp2.y;	// dv/dx
                gradvelp1.a23+=vfrz*velrhopp2.y;	// dv/dx
                gradvelp1.a31+=vfrx*velrhopp2.z;	// dw/dx
                gradvelp1.a32+=vfry*velrhopp2.z;	// dw/dx
                gradvelp1.a33+=vfrz*velrhopp2.z;	// dw/dx
              }

              //===== Matrix A for correction =====
              if(sim2d){
                a_corr2.a11+=vwab; 	a_corr2.a12+=drx*vwab;	a_corr2.a13+=drz*vwab;
                a_corr2.a21+=vfrx; 	a_corr2.a22+=drx*vfrx; 	a_corr2.a23+=drz*vfrx;
                a_corr2.a31+=vfrz; 	a_corr2.a32+=drx*vfrz;	a_corr2.a33+=drz*vfrz;
              }
              else{
                a_corr3.a11+=vwab;  a_corr3.a12+=drx*vwab;  a_corr3.a13+=dry*vwab;  a_corr3.a14+=drz*vwab;
                a_corr3.a21+=vfrx;  a_corr3.a22+=drx*vfrx;  a_corr3.a23+=dry*vfrx;  a_corr3.a24+=drz*vfrx;
                a_corr3.a31+=vfry;  a_corr3.a32+=drx*vfry;  a_corr3.a33+=dry*vfry;  a_corr3.a34+=drz*vfry;
                a_corr3.a41+=vfrz;  a_corr3.a42+=drx*vfrz;  a_corr3.a43+=dry*vfrz;  a_corr3.a44+=drz*vfrz;
              }
            }
          }
        }
      }

      //-Store the results.
      //--------------------
      float4 velrhopfinal=velrhop[p1];
      const double3 dpos=make_double3(pos_p1.x-posp1.x, pos_p1.y-posp1.y, pos_p1.z-posp1.z); //-Inlet/outlet particle position - ghost node position.
      if(sim2d){
        const double determ=cumath::Determinant3x3(a_corr2);
        if(determ>=determlimit){//-Use 1e-3f (first_order) or 1e+3f (zeroth_order).
          const tmatrix3d invacorr2=cumath::InverseMatrix3x3(a_corr2,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          if(computerhop){
            const double rhoghost=rhopp1*invacorr2.a11 + gradrhopp1.x*invacorr2.a12 + gradrhopp1.z*invacorr2.a13;
            const double grx=-(rhopp1*invacorr2.a21 + gradrhopp1.x*invacorr2.a22 + gradrhopp1.z*invacorr2.a23);
            const double grz=-(rhopp1*invacorr2.a31 + gradrhopp1.x*invacorr2.a32 + gradrhopp1.z*invacorr2.a33);
            velrhopfinal.w=float(rhoghost + grx*dpos.x + grz*dpos.z);
          }
          //-GHOST NODE VELOCITY ARE MIRRORED BACK TO THE OUTFLOW PARTICLES.
          if(computevel){
            const double velghost_x=velp1.x*invacorr2.a11 + gradvelp1.a11*invacorr2.a12 + gradvelp1.a13*invacorr2.a13;
            const double velghost_z=velp1.z*invacorr2.a11 + gradvelp1.a31*invacorr2.a12 + gradvelp1.a33*invacorr2.a13;
            const double a11=-(velp1.x*invacorr2.a21 + gradvelp1.a11*invacorr2.a22 + gradvelp1.a13*invacorr2.a23);
            const double a13=-(velp1.z*invacorr2.a21 + gradvelp1.a31*invacorr2.a22 + gradvelp1.a33*invacorr2.a23);
            const double a31=-(velp1.x*invacorr2.a31 + gradvelp1.a11*invacorr2.a32 + gradvelp1.a13*invacorr2.a33);
            const double a33=-(velp1.z*invacorr2.a31 + gradvelp1.a31*invacorr2.a32 + gradvelp1.a33*invacorr2.a33);
    	    velrhopfinal.x=float(velghost_x + a11*dpos.x + a31*dpos.z);
    	    velrhopfinal.z=float(velghost_z + a13*dpos.x + a33*dpos.z);
            velrhopfinal.y=0;
   	      }
        }
        else if(a_corr2.a11>0){//-Determinant is small but a11 is nonzero, 0th order ANGELO.
          if(computerhop)velrhopfinal.w=float(rhopp1/a_corr2.a11);
          if(computevel){
            velrhopfinal.x=float(velp1.x/a_corr2.a11);
            velrhopfinal.z=float(velp1.z/a_corr2.a11);
            velrhopfinal.y=0;
   	      }
        }
      }
      else{
        const double determ=cumath::Determinant4x4(a_corr3);
        if(determ>=determlimit){
          const tmatrix4d invacorr3=cumath::InverseMatrix4x4(a_corr3,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          if(computerhop){
            const double rhoghost=rhopp1*invacorr3.a11 + gradrhopp1.x*invacorr3.a12 + gradrhopp1.y*invacorr3.a13 + gradrhopp1.z*invacorr3.a14;
            const double grx=   -(rhopp1*invacorr3.a21 + gradrhopp1.x*invacorr3.a22 + gradrhopp1.y*invacorr3.a23 + gradrhopp1.z*invacorr3.a24);
            const double gry=   -(rhopp1*invacorr3.a31 + gradrhopp1.x*invacorr3.a32 + gradrhopp1.y*invacorr3.a33 + gradrhopp1.z*invacorr3.a34);
            const double grz=   -(rhopp1*invacorr3.a41 + gradrhopp1.x*invacorr3.a42 + gradrhopp1.y*invacorr3.a43 + gradrhopp1.z*invacorr3.a44);
            velrhopfinal.w=float(rhoghost + grx*dpos.x + gry*dpos.y + grz*dpos.z);
          }
          //-GHOST NODE VELOCITY ARE MIRRORED BACK TO THE OUTFLOW PARTICLES.
          if(computevel){
            const double velghost_x=velp1.x*invacorr3.a11 + gradvelp1.a11*invacorr3.a12 + gradvelp1.a12*invacorr3.a13 + gradvelp1.a13*invacorr3.a14;
      	    const double velghost_y=velp1.y*invacorr3.a11 + gradvelp1.a11*invacorr3.a12 + gradvelp1.a12*invacorr3.a13 + gradvelp1.a13*invacorr3.a14;
      	    const double velghost_z=velp1.z*invacorr3.a11 + gradvelp1.a31*invacorr3.a12 + gradvelp1.a32*invacorr3.a13 + gradvelp1.a33*invacorr3.a14;
            const double a11=-(velp1.x*invacorr3.a21 + gradvelp1.a11*invacorr3.a22 + gradvelp1.a12*invacorr3.a23 + gradvelp1.a13*invacorr3.a24);
        	const double a12=-(velp1.y*invacorr3.a21 + gradvelp1.a21*invacorr3.a22 + gradvelp1.a22*invacorr3.a23 + gradvelp1.a23*invacorr3.a24);
        	const double a13=-(velp1.z*invacorr3.a21 + gradvelp1.a31*invacorr3.a22 + gradvelp1.a32*invacorr3.a23 + gradvelp1.a33*invacorr3.a24);
        	const double a21=-(velp1.x*invacorr3.a31 + gradvelp1.a11*invacorr3.a32 + gradvelp1.a12*invacorr3.a33 + gradvelp1.a13*invacorr3.a34);
        	const double a22=-(velp1.y*invacorr3.a31 + gradvelp1.a21*invacorr3.a32 + gradvelp1.a22*invacorr3.a33 + gradvelp1.a23*invacorr3.a34);
        	const double a23=-(velp1.z*invacorr3.a31 + gradvelp1.a31*invacorr3.a32 + gradvelp1.a32*invacorr3.a33 + gradvelp1.a33*invacorr3.a34);
        	const double a31=-(velp1.x*invacorr3.a41 + gradvelp1.a11*invacorr3.a42 + gradvelp1.a12*invacorr3.a43 + gradvelp1.a13*invacorr3.a44);
        	const double a32=-(velp1.y*invacorr3.a41 + gradvelp1.a21*invacorr3.a42 + gradvelp1.a22*invacorr3.a43 + gradvelp1.a23*invacorr3.a44);
        	const double a33=-(velp1.z*invacorr3.a41 + gradvelp1.a31*invacorr3.a42 + gradvelp1.a32*invacorr3.a43 + gradvelp1.a33*invacorr3.a44);
            velrhopfinal.x=float(velghost_x + a11*dpos.x + a21*dpos.y + a31*dpos.z);
            velrhopfinal.y=float(velghost_y + a12*dpos.x + a22*dpos.y + a32*dpos.z);
      	    velrhopfinal.z=float(velghost_z + a13*dpos.x + a23*dpos.y + a33*dpos.z);
          }
        }
        else if(a_corr3.a11>0){ // Determinant is small but a11 is nonzero, 0th order ANGELO
          if(computerhop)velrhopfinal.w=float(rhopp1/a_corr3.a11);
          if(computevel){
            velrhopfinal.x=float(velp1.x/a_corr3.a11);
            velrhopfinal.y=float(velp1.y/a_corr3.a11);
            velrhopfinal.z=float(velp1.z/a_corr3.a11);
     	  }
        }
      }
      velrhop[p1]=velrhopfinal;
    }
  }
}

//------------------------------------------------------------------------------
/// Perform interaction between ghost inlet/outlet nodes and fluid particles. GhostNodes-Fluid
/// Realiza interaccion entre ghost inlet/outlet nodes y particulas de fluido. GhostNodes-Fluid
//------------------------------------------------------------------------------
template<bool sim2d,TpKernel tker> __global__ void KerInteractionInOutExtrap_Single
  (unsigned inoutcount,const int *inoutpart,const byte *cfgzone,byte computerhopmask,byte computevelmask
  ,const float4 *planes,const float* width,const float3 *dirdata,float determlimit
  ,int hdiv,int4 nc,unsigned cellfluid,const int2 *begincell,int3 cellzero
  ,const double2 *posxy,const double *posz,const typecode *code,const unsigned *idp
  ,float4 *velrhop)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<inoutcount){
    const unsigned p1=inoutpart[cp];
    const byte izone=byte(CODE_GetIzoneFluidInout(code[p1]));
    const byte cfg=cfgzone[izone];
    const bool computerhop=((cfg&computerhopmask)!=0);
    const bool computevel= ((cfg&computevelmask )!=0);
    if(computerhop || computevel){
      //-Calculates ghost node position.
      double3 pos_p1=make_double3(posxy[p1].x,posxy[p1].y,posz[p1]);
      if(CODE_IsPeriodic(code[p1]))pos_p1=KerInteraction_PosNoPeriodic(pos_p1);
      const double displane=cumath::DistPlane(planes[izone],pos_p1)*2;
      const float3 rdirdata=dirdata[izone];
      const double3 posp1=make_double3(pos_p1.x+displane*rdirdata.x, pos_p1.y+displane*rdirdata.y, pos_p1.z+displane*rdirdata.z); //-Ghost node position.

      //-Initializes variables for calculation.
      float rhopp1=0;
      float3 gradrhopp1=make_float3(0,0,0);
      float3 velp1=make_float3(0,0,0);
      tmatrix3f gradvelp1; cumath::Tmatrix3fReset(gradvelp1); //-Only for velocity.
      tmatrix3d a_corr2; if(sim2d) cumath::Tmatrix3dReset(a_corr2); //-Only for 2D.
      tmatrix4d a_corr3; if(!sim2d)cumath::Tmatrix4dReset(a_corr3); //-Only for 3D.

      //-Obtains interaction limits.
      int cxini,cxfin,yini,yfin,zini,zfin;
      cusph::KerGetInteractionCells(posp1.x,posp1.y,posp1.z,hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

      //-Interaction with fluids.
      for(int z=zini;z<zfin;z++){
        int zmod=(nc.w)*z+cellfluid; //-The sum showing where fluid cells start. | Le suma donde empiezan las celdas de fluido.
        for(int y=yini;y<yfin;y++){
          int ymod=zmod+nc.x*y;
          unsigned pini,pfin=0;
          for(int x=cxini;x<cxfin;x++){
            int2 cbeg=begincell[x+ymod];
            if(cbeg.y){
              if(!pfin)pini=cbeg.x;
              pfin=cbeg.y;
            }
          }
          if(pfin)for(unsigned p2=pini;p2<pfin;p2++){
            const double2 p2xy=posxy[p2];
            const float drx=float(posp1.x-p2xy.x);
            const float dry=float(posp1.y-p2xy.y);
            const float drz=float(posp1.z-posz[p2]);
            const float rr2=drx*drx+dry*dry+drz*drz;
            if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO && CODE_IsFluidNotInout(code[p2])){//-Only with fluid particles but not inout particles.
              //-Wendland or Cubic Spline kernel.
			  float frx,fry,frz,wab;
			  if(tker==KERNEL_Wendland)cusph::KerGetKernelWendland(rr2,drx,dry,drz,frx,fry,frz,wab);
			  else if(tker==KERNEL_Cubic)cusph::KerGetKernelCubic(rr2,drx,dry,drz,frx,fry,frz,wab);

              const float4 velrhopp2=velrhop[p2];
              //===== Get mass and volume of particle p2 =====
              float massp2=CTE.massf;
              float volp2=massp2/velrhopp2.w;

              //===== Density and its gradient =====
              rhopp1+=massp2*wab;
              gradrhopp1.x+=massp2*frx;
              gradrhopp1.y+=massp2*fry;
              gradrhopp1.z+=massp2*frz;

              //===== Kernel values multiplied by volume =====
              const float vwab=wab*volp2;
              const float vfrx=frx*volp2;
              const float vfry=fry*volp2;
              const float vfrz=frz*volp2;

              //===== Velocity and its gradient =====
              if(computevel){
                velp1.x+=vwab*velrhopp2.x;
                velp1.y+=vwab*velrhopp2.y;
                velp1.z+=vwab*velrhopp2.z;
                gradvelp1.a11+=vfrx*velrhopp2.x;	// du/dx
                gradvelp1.a12+=vfry*velrhopp2.x;	// du/dy
                gradvelp1.a13+=vfrz*velrhopp2.x;	// du/dz
                gradvelp1.a21+=vfrx*velrhopp2.y;	// dv/dx
                gradvelp1.a22+=vfry*velrhopp2.y;	// dv/dx
                gradvelp1.a23+=vfrz*velrhopp2.y;	// dv/dx
                gradvelp1.a31+=vfrx*velrhopp2.z;	// dw/dx
                gradvelp1.a32+=vfry*velrhopp2.z;	// dw/dx
                gradvelp1.a33+=vfrz*velrhopp2.z;	// dw/dx
              }

              //===== Matrix A for correction =====
              if(sim2d){
                a_corr2.a11+=vwab; 	a_corr2.a12+=drx*vwab;	a_corr2.a13+=drz*vwab;
                a_corr2.a21+=vfrx; 	a_corr2.a22+=drx*vfrx; 	a_corr2.a23+=drz*vfrx;
                a_corr2.a31+=vfrz; 	a_corr2.a32+=drx*vfrz;	a_corr2.a33+=drz*vfrz;
              }
              else{
                a_corr3.a11+=vwab;  a_corr3.a12+=drx*vwab;  a_corr3.a13+=dry*vwab;  a_corr3.a14+=drz*vwab;
                a_corr3.a21+=vfrx;  a_corr3.a22+=drx*vfrx;  a_corr3.a23+=dry*vfrx;  a_corr3.a24+=drz*vfrx;
                a_corr3.a31+=vfry;  a_corr3.a32+=drx*vfry;  a_corr3.a33+=dry*vfry;  a_corr3.a34+=drz*vfry;
                a_corr3.a41+=vfrz;  a_corr3.a42+=drx*vfrz;  a_corr3.a43+=dry*vfrz;  a_corr3.a44+=drz*vfrz;
              }
            }
          }
        }
      }

      //-Store the results.
      //--------------------
      float4 velrhopfinal=velrhop[p1];
      const float3 dpos=make_float3(float(pos_p1.x-posp1.x),float(pos_p1.y-posp1.y),float(pos_p1.z-posp1.z)); //-Inlet/outlet particle position - ghost node position.
      if(sim2d){
        const double determ=cumath::Determinant3x3(a_corr2);
        if(determ>=determlimit){//-Use 1e-3f (first_order) or 1e+3f (zeroth_order).
          const tmatrix3d invacorr2=cumath::InverseMatrix3x3(a_corr2,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          if(computerhop){
            const float rhoghost=float(invacorr2.a11*rhopp1 + invacorr2.a12*gradrhopp1.x + invacorr2.a13*gradrhopp1.z);
            const float grx=    -float(invacorr2.a21*rhopp1 + invacorr2.a22*gradrhopp1.x + invacorr2.a23*gradrhopp1.z);
            const float grz=    -float(invacorr2.a31*rhopp1 + invacorr2.a32*gradrhopp1.x + invacorr2.a33*gradrhopp1.z);
            velrhopfinal.w=(rhoghost + grx*dpos.x + grz*dpos.z);
          }
          //-GHOST NODE VELOCITY ARE MIRRORED BACK TO THE OUTFLOW PARTICLES.
          if(computevel){
            const float velghost_x=float(invacorr2.a11*velp1.x + invacorr2.a12*gradvelp1.a11 + invacorr2.a13*gradvelp1.a13);
            const float velghost_z=float(invacorr2.a11*velp1.z + invacorr2.a12*gradvelp1.a31 + invacorr2.a13*gradvelp1.a33);
            const float a11=-float(invacorr2.a21*velp1.x + invacorr2.a22*gradvelp1.a11 + invacorr2.a23*gradvelp1.a13);
            const float a13=-float(invacorr2.a21*velp1.z + invacorr2.a22*gradvelp1.a31 + invacorr2.a23*gradvelp1.a33);
            const float a31=-float(invacorr2.a31*velp1.x + invacorr2.a32*gradvelp1.a11 + invacorr2.a33*gradvelp1.a13);
            const float a33=-float(invacorr2.a31*velp1.z + invacorr2.a32*gradvelp1.a31 + invacorr2.a33*gradvelp1.a33);
    	    velrhopfinal.x=(velghost_x + a11*dpos.x + a31*dpos.z);
    	    velrhopfinal.z=(velghost_z + a13*dpos.x + a33*dpos.z);
            velrhopfinal.y=0;
   	      }
        }
        else if(a_corr2.a11>0){//-Determinant is small but a11 is nonzero, 0th order ANGELO.
          if(computerhop)velrhopfinal.w=float(rhopp1/a_corr2.a11);
          if(computevel){
            velrhopfinal.x=float(velp1.x/a_corr2.a11);
            velrhopfinal.z=float(velp1.z/a_corr2.a11);
            velrhopfinal.y=0;
   	      }
        }
      }
      else{
        const double determ=cumath::Determinant4x4(a_corr3);
        if(determ>=determlimit){
          const tmatrix4d invacorr3=cumath::InverseMatrix4x4(a_corr3,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          if(computerhop){
            const float rhoghost=float(invacorr3.a11*rhopp1 + invacorr3.a12*gradrhopp1.x + invacorr3.a13*gradrhopp1.y + invacorr3.a14*gradrhopp1.z);
            const float grx=    -float(invacorr3.a21*rhopp1 + invacorr3.a22*gradrhopp1.x + invacorr3.a23*gradrhopp1.y + invacorr3.a24*gradrhopp1.z);
            const float gry=    -float(invacorr3.a31*rhopp1 + invacorr3.a32*gradrhopp1.x + invacorr3.a33*gradrhopp1.y + invacorr3.a34*gradrhopp1.z);
            const float grz=    -float(invacorr3.a41*rhopp1 + invacorr3.a42*gradrhopp1.x + invacorr3.a43*gradrhopp1.y + invacorr3.a44*gradrhopp1.z);
            velrhopfinal.w=(rhoghost + grx*dpos.x + gry*dpos.y + grz*dpos.z);
          }
          //-GHOST NODE VELOCITY ARE MIRRORED BACK TO THE OUTFLOW PARTICLES.
          if(computevel){
            const float velghost_x=float(invacorr3.a11*velp1.x + invacorr3.a12*gradvelp1.a11 + invacorr3.a13*gradvelp1.a12 + invacorr3.a14*gradvelp1.a13);
      	    const float velghost_y=float(invacorr3.a11*velp1.y + invacorr3.a12*gradvelp1.a11 + invacorr3.a13*gradvelp1.a12 + invacorr3.a14*gradvelp1.a13);
      	    const float velghost_z=float(invacorr3.a11*velp1.z + invacorr3.a12*gradvelp1.a31 + invacorr3.a13*gradvelp1.a32 + invacorr3.a14*gradvelp1.a33);
            const float a11=      -float(invacorr3.a21*velp1.x + invacorr3.a22*gradvelp1.a11 + invacorr3.a23*gradvelp1.a12 + invacorr3.a24*gradvelp1.a13);
        	const float a12=      -float(invacorr3.a21*velp1.y + invacorr3.a22*gradvelp1.a21 + invacorr3.a23*gradvelp1.a22 + invacorr3.a24*gradvelp1.a23);
        	const float a13=      -float(invacorr3.a21*velp1.z + invacorr3.a22*gradvelp1.a31 + invacorr3.a23*gradvelp1.a32 + invacorr3.a24*gradvelp1.a33);
        	const float a21=      -float(invacorr3.a31*velp1.x + invacorr3.a32*gradvelp1.a11 + invacorr3.a33*gradvelp1.a12 + invacorr3.a34*gradvelp1.a13);
        	const float a22=      -float(invacorr3.a31*velp1.y + invacorr3.a32*gradvelp1.a21 + invacorr3.a33*gradvelp1.a22 + invacorr3.a34*gradvelp1.a23);
        	const float a23=      -float(invacorr3.a31*velp1.z + invacorr3.a32*gradvelp1.a31 + invacorr3.a33*gradvelp1.a32 + invacorr3.a34*gradvelp1.a33);
        	const float a31=      -float(invacorr3.a41*velp1.x + invacorr3.a42*gradvelp1.a11 + invacorr3.a43*gradvelp1.a12 + invacorr3.a44*gradvelp1.a13);
        	const float a32=      -float(invacorr3.a41*velp1.y + invacorr3.a42*gradvelp1.a21 + invacorr3.a43*gradvelp1.a22 + invacorr3.a44*gradvelp1.a23);
        	const float a33=      -float(invacorr3.a41*velp1.z + invacorr3.a42*gradvelp1.a31 + invacorr3.a43*gradvelp1.a32 + invacorr3.a44*gradvelp1.a33);
            velrhopfinal.x=(velghost_x + a11*dpos.x + a21*dpos.y + a31*dpos.z);
            velrhopfinal.y=(velghost_y + a12*dpos.x + a22*dpos.y + a32*dpos.z);
      	    velrhopfinal.z=(velghost_z + a13*dpos.x + a23*dpos.y + a33*dpos.z);
          }
        }
        else if(a_corr3.a11>0){ // Determinant is small but a11 is nonzero, 0th order ANGELO
          if(computerhop)velrhopfinal.w=float(rhopp1/a_corr3.a11);
          if(computevel){
            velrhopfinal.x=float(velp1.x/a_corr3.a11);
            velrhopfinal.y=float(velp1.y/a_corr3.a11);
            velrhopfinal.z=float(velp1.z/a_corr3.a11);
     	  }
        }
      }
      velrhop[p1]=velrhopfinal;
    }
  }
}


//------------------------------------------------------------------------------
/// Perform interaction between ghost inlet/outlet nodes and fluid particles. GhostNodes-Fluid
/// Realiza interaccion entre ghost inlet/outlet nodes y particulas de fluido. GhostNodes-Fluid
//------------------------------------------------------------------------------
template<bool sim2d,TpKernel tker> __global__ void KerInteractionInOutExtrap_FastSingle
  (unsigned inoutcount,const int *inoutpart,const byte *cfgzone,byte computerhopmask,byte computevelmask
  ,const float4 *planes,const float* width,const float3 *dirdata,float determlimit
  ,int hdiv,int4 nc,unsigned cellfluid,const int2 *begincell,int3 cellzero
  ,const double2 *posxy,const double *posz,const typecode *code,const unsigned *idp
  ,float4 *velrhop)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<inoutcount){
    const unsigned p1=inoutpart[cp];
    const byte izone=byte(CODE_GetIzoneFluidInout(code[p1]));
    const byte cfg=cfgzone[izone];
    const bool computerhop=((cfg&computerhopmask)!=0);
    const bool computevel= ((cfg&computevelmask )!=0);
    if(computerhop || computevel){
      //-Calculates ghost node position.
      double3 pos_p1=make_double3(posxy[p1].x,posxy[p1].y,posz[p1]);
      if(CODE_IsPeriodic(code[p1]))pos_p1=KerInteraction_PosNoPeriodic(pos_p1);
      const double displane=cumath::DistPlane(planes[izone],pos_p1)*2;
      const float3 rdirdata=dirdata[izone];
      const double3 posp1=make_double3(pos_p1.x+displane*rdirdata.x, pos_p1.y+displane*rdirdata.y, pos_p1.z+displane*rdirdata.z); //-Ghost node position.

      //-Initializes variables for calculation.
      float rhopp1=0;
      float3 gradrhopp1=make_float3(0,0,0);
      float3 velp1=make_float3(0,0,0);
      tmatrix3f gradvelp1; cumath::Tmatrix3fReset(gradvelp1); //-Only for velocity.
      tmatrix3f a_corr2; if(sim2d) cumath::Tmatrix3fReset(a_corr2); //-Only for 2D.
      tmatrix4f a_corr3; if(!sim2d)cumath::Tmatrix4fReset(a_corr3); //-Only for 3D.

      //-Obtains interaction limits.
      int cxini,cxfin,yini,yfin,zini,zfin;
      cusph::KerGetInteractionCells(posp1.x,posp1.y,posp1.z,hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

      //-Interaction with fluids.
      for(int z=zini;z<zfin;z++){
        int zmod=(nc.w)*z+cellfluid; //-The sum showing where fluid cells start. | Le suma donde empiezan las celdas de fluido.
        for(int y=yini;y<yfin;y++){
          int ymod=zmod+nc.x*y;
          unsigned pini,pfin=0;
          for(int x=cxini;x<cxfin;x++){
            int2 cbeg=begincell[x+ymod];
            if(cbeg.y){
              if(!pfin)pini=cbeg.x;
              pfin=cbeg.y;
            }
          }
          if(pfin)for(unsigned p2=pini;p2<pfin;p2++){
            const double2 p2xy=posxy[p2];
            const float drx=float(posp1.x-p2xy.x);
            const float dry=float(posp1.y-p2xy.y);
            const float drz=float(posp1.z-posz[p2]);
            const float rr2=drx*drx+dry*dry+drz*drz;
            if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO && CODE_IsFluidNotInout(code[p2])){//-Only with fluid particles but not inout particles.
              //-Wendland or Cubic Spline kernel.
			  float frx,fry,frz,wab;
			  if(tker==KERNEL_Wendland)cusph::KerGetKernelWendland(rr2,drx,dry,drz,frx,fry,frz,wab);
			  else if(tker==KERNEL_Cubic)cusph::KerGetKernelCubic(rr2,drx,dry,drz,frx,fry,frz,wab);

              const float4 velrhopp2=velrhop[p2];
              //===== Get mass and volume of particle p2 =====
              float massp2=CTE.massf;
              float volp2=massp2/velrhopp2.w;

              //===== Density and its gradient =====
              rhopp1+=massp2*wab;
              gradrhopp1.x+=massp2*frx;
              gradrhopp1.y+=massp2*fry;
              gradrhopp1.z+=massp2*frz;

              //===== Kernel values multiplied by volume =====
              const float vwab=wab*volp2;
              const float vfrx=frx*volp2;
              const float vfry=fry*volp2;
              const float vfrz=frz*volp2;

              //===== Velocity and its gradient =====
              if(computevel){
                velp1.x+=vwab*velrhopp2.x;
                velp1.y+=vwab*velrhopp2.y;
                velp1.z+=vwab*velrhopp2.z;
                gradvelp1.a11+=vfrx*velrhopp2.x;	// du/dx
                gradvelp1.a12+=vfry*velrhopp2.x;	// du/dy
                gradvelp1.a13+=vfrz*velrhopp2.x;	// du/dz
                gradvelp1.a21+=vfrx*velrhopp2.y;	// dv/dx
                gradvelp1.a22+=vfry*velrhopp2.y;	// dv/dx
                gradvelp1.a23+=vfrz*velrhopp2.y;	// dv/dx
                gradvelp1.a31+=vfrx*velrhopp2.z;	// dw/dx
                gradvelp1.a32+=vfry*velrhopp2.z;	// dw/dx
                gradvelp1.a33+=vfrz*velrhopp2.z;	// dw/dx
              }

              //===== Matrix A for correction =====
              if(sim2d){
                a_corr2.a11+=vwab; 	a_corr2.a12+=drx*vwab;	a_corr2.a13+=drz*vwab;
                a_corr2.a21+=vfrx; 	a_corr2.a22+=drx*vfrx; 	a_corr2.a23+=drz*vfrx;
                a_corr2.a31+=vfrz; 	a_corr2.a32+=drx*vfrz;	a_corr2.a33+=drz*vfrz;
              }
              else{
                a_corr3.a11+=vwab;  a_corr3.a12+=drx*vwab;  a_corr3.a13+=dry*vwab;  a_corr3.a14+=drz*vwab;
                a_corr3.a21+=vfrx;  a_corr3.a22+=drx*vfrx;  a_corr3.a23+=dry*vfrx;  a_corr3.a24+=drz*vfrx;
                a_corr3.a31+=vfry;  a_corr3.a32+=drx*vfry;  a_corr3.a33+=dry*vfry;  a_corr3.a34+=drz*vfry;
                a_corr3.a41+=vfrz;  a_corr3.a42+=drx*vfrz;  a_corr3.a43+=dry*vfrz;  a_corr3.a44+=drz*vfrz;
              }
            }
          }
        }
      }

      //-Store the results.
      //--------------------
      float4 velrhopfinal=velrhop[p1];
      const float3 dpos=make_float3(float(pos_p1.x-posp1.x),float(pos_p1.y-posp1.y),float(pos_p1.z-posp1.z)); //-Inlet/outlet particle position - ghost node position.
      if(sim2d){
        const double determ=cumath::Determinant3x3dbl(a_corr2);
        if(determ>=determlimit){//-Use 1e-3f (first_order) or 1e+3f (zeroth_order).
          const tmatrix3f invacorr2=cumath::InverseMatrix3x3dbl(a_corr2,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          if(computerhop){
            const float rhoghost=float(invacorr2.a11*rhopp1 + invacorr2.a12*gradrhopp1.x + invacorr2.a13*gradrhopp1.z);
            const float grx=    -float(invacorr2.a21*rhopp1 + invacorr2.a22*gradrhopp1.x + invacorr2.a23*gradrhopp1.z);
            const float grz=    -float(invacorr2.a31*rhopp1 + invacorr2.a32*gradrhopp1.x + invacorr2.a33*gradrhopp1.z);
            velrhopfinal.w=(rhoghost + grx*dpos.x + grz*dpos.z);
          }
          //-GHOST NODE VELOCITY ARE MIRRORED BACK TO THE OUTFLOW PARTICLES.
          if(computevel){
            const float velghost_x=float(invacorr2.a11*velp1.x + invacorr2.a12*gradvelp1.a11 + invacorr2.a13*gradvelp1.a13);
            const float velghost_z=float(invacorr2.a11*velp1.z + invacorr2.a12*gradvelp1.a31 + invacorr2.a13*gradvelp1.a33);
            const float a11=-float(invacorr2.a21*velp1.x + invacorr2.a22*gradvelp1.a11 + invacorr2.a23*gradvelp1.a13);
            const float a13=-float(invacorr2.a21*velp1.z + invacorr2.a22*gradvelp1.a31 + invacorr2.a23*gradvelp1.a33);
            const float a31=-float(invacorr2.a31*velp1.x + invacorr2.a32*gradvelp1.a11 + invacorr2.a33*gradvelp1.a13);
            const float a33=-float(invacorr2.a31*velp1.z + invacorr2.a32*gradvelp1.a31 + invacorr2.a33*gradvelp1.a33);
    	    velrhopfinal.x=(velghost_x + a11*dpos.x + a31*dpos.z);
    	    velrhopfinal.z=(velghost_z + a13*dpos.x + a33*dpos.z);
            velrhopfinal.y=0;
   	      }
        }
        else if(a_corr2.a11>0){//-Determinant is small but a11 is nonzero, 0th order ANGELO.
          if(computerhop)velrhopfinal.w=float(rhopp1/a_corr2.a11);
          if(computevel){
            velrhopfinal.x=float(velp1.x/a_corr2.a11);
            velrhopfinal.z=float(velp1.z/a_corr2.a11);
            velrhopfinal.y=0;
   	      }
        }
      }
      else{
        const double determ=cumath::Determinant4x4dbl(a_corr3);
        if(determ>=determlimit){
          const tmatrix4f invacorr3=cumath::InverseMatrix4x4dbl(a_corr3,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          if(computerhop){
            const float rhoghost=float(invacorr3.a11*rhopp1 + invacorr3.a12*gradrhopp1.x + invacorr3.a13*gradrhopp1.y + invacorr3.a14*gradrhopp1.z);
            const float grx=    -float(invacorr3.a21*rhopp1 + invacorr3.a22*gradrhopp1.x + invacorr3.a23*gradrhopp1.y + invacorr3.a24*gradrhopp1.z);
            const float gry=    -float(invacorr3.a31*rhopp1 + invacorr3.a32*gradrhopp1.x + invacorr3.a33*gradrhopp1.y + invacorr3.a34*gradrhopp1.z);
            const float grz=    -float(invacorr3.a41*rhopp1 + invacorr3.a42*gradrhopp1.x + invacorr3.a43*gradrhopp1.y + invacorr3.a44*gradrhopp1.z);
            velrhopfinal.w=(rhoghost + grx*dpos.x + gry*dpos.y + grz*dpos.z);
          }
          //-GHOST NODE VELOCITY ARE MIRRORED BACK TO THE OUTFLOW PARTICLES.
          if(computevel){
            const float velghost_x=float(invacorr3.a11*velp1.x + invacorr3.a12*gradvelp1.a11 + invacorr3.a13*gradvelp1.a12 + invacorr3.a14*gradvelp1.a13);
      	    const float velghost_y=float(invacorr3.a11*velp1.y + invacorr3.a12*gradvelp1.a11 + invacorr3.a13*gradvelp1.a12 + invacorr3.a14*gradvelp1.a13);
      	    const float velghost_z=float(invacorr3.a11*velp1.z + invacorr3.a12*gradvelp1.a31 + invacorr3.a13*gradvelp1.a32 + invacorr3.a14*gradvelp1.a33);
            const float a11=      -float(invacorr3.a21*velp1.x + invacorr3.a22*gradvelp1.a11 + invacorr3.a23*gradvelp1.a12 + invacorr3.a24*gradvelp1.a13);
        	const float a12=      -float(invacorr3.a21*velp1.y + invacorr3.a22*gradvelp1.a21 + invacorr3.a23*gradvelp1.a22 + invacorr3.a24*gradvelp1.a23);
        	const float a13=      -float(invacorr3.a21*velp1.z + invacorr3.a22*gradvelp1.a31 + invacorr3.a23*gradvelp1.a32 + invacorr3.a24*gradvelp1.a33);
        	const float a21=      -float(invacorr3.a31*velp1.x + invacorr3.a32*gradvelp1.a11 + invacorr3.a33*gradvelp1.a12 + invacorr3.a34*gradvelp1.a13);
        	const float a22=      -float(invacorr3.a31*velp1.y + invacorr3.a32*gradvelp1.a21 + invacorr3.a33*gradvelp1.a22 + invacorr3.a34*gradvelp1.a23);
        	const float a23=      -float(invacorr3.a31*velp1.z + invacorr3.a32*gradvelp1.a31 + invacorr3.a33*gradvelp1.a32 + invacorr3.a34*gradvelp1.a33);
        	const float a31=      -float(invacorr3.a41*velp1.x + invacorr3.a42*gradvelp1.a11 + invacorr3.a43*gradvelp1.a12 + invacorr3.a44*gradvelp1.a13);
        	const float a32=      -float(invacorr3.a41*velp1.y + invacorr3.a42*gradvelp1.a21 + invacorr3.a43*gradvelp1.a22 + invacorr3.a44*gradvelp1.a23);
        	const float a33=      -float(invacorr3.a41*velp1.z + invacorr3.a42*gradvelp1.a31 + invacorr3.a43*gradvelp1.a32 + invacorr3.a44*gradvelp1.a33);
            velrhopfinal.x=(velghost_x + a11*dpos.x + a21*dpos.y + a31*dpos.z);
            velrhopfinal.y=(velghost_y + a12*dpos.x + a22*dpos.y + a32*dpos.z);
      	    velrhopfinal.z=(velghost_z + a13*dpos.x + a23*dpos.y + a33*dpos.z);
          }
        }
        else if(a_corr3.a11>0){ // Determinant is small but a11 is nonzero, 0th order ANGELO
          if(computerhop)velrhopfinal.w=float(rhopp1/a_corr3.a11);
          if(computevel){
            velrhopfinal.x=float(velp1.x/a_corr3.a11);
            velrhopfinal.y=float(velp1.y/a_corr3.a11);
            velrhopfinal.z=float(velp1.z/a_corr3.a11);
     	  }
        }
      }
      velrhop[p1]=velrhopfinal;
    }
  }
}

//==============================================================================
/// Perform interaction between ghost inlet/outlet nodes and fluid particles. GhostNodes-Fluid
/// Realiza interaccion entre ghost inlet/outlet nodes y particulas de fluido. GhostNodes-Fluid
//==============================================================================
void Interaction_InOutExtrap(byte doublemode,bool simulate2d,TpKernel tkernel,TpCellMode cellmode
  ,unsigned inoutcount,const int *inoutpart,const byte *cfgzone,byte computerhopmask,byte computevelmask
  ,const float4 *planes,const float* width,const float3 *dirdata,float determlimit
  ,tuint3 ncells,const int2 *begincell,tuint3 cellmin
  ,const double2 *posxy,const double *posz,const typecode *code,const unsigned *idp
  ,float4 *velrhop)
{
  //-Executes particle interactions.
  const int hdiv=(cellmode==CELLMODE_H? 2: 1);
  const int4 nc=make_int4(int(ncells.x),int(ncells.y),int(ncells.z),int(ncells.x*ncells.y));
  const unsigned cellfluid=nc.w*nc.z+1;
  const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
  //-Interaction GhostBoundaryNodes-Fluid.
  if(inoutcount){
    const unsigned bsize=128;
    dim3 sgrid=cusph::GetGridSize(inoutcount,bsize);
    if(doublemode==1){
      if(simulate2d){ const bool sim2d=true;
        if(tkernel==KERNEL_Wendland)KerInteractionInOutExtrap_FastSingle<sim2d,KERNEL_Wendland> <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionInOutExtrap_FastSingle<sim2d,KERNEL_Cubic>    <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }else{          const bool sim2d=false;
        if(tkernel==KERNEL_Wendland)KerInteractionInOutExtrap_FastSingle<sim2d,KERNEL_Wendland> <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionInOutExtrap_FastSingle<sim2d,KERNEL_Cubic>    <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }
    }
    else if(doublemode==2){
      if(simulate2d){ const bool sim2d=true;
        if(tkernel==KERNEL_Wendland)KerInteractionInOutExtrap_Single<sim2d,KERNEL_Wendland> <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionInOutExtrap_Single<sim2d,KERNEL_Cubic>    <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }else{          const bool sim2d=false;
        if(tkernel==KERNEL_Wendland)KerInteractionInOutExtrap_Single<sim2d,KERNEL_Wendland> <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionInOutExtrap_Single<sim2d,KERNEL_Cubic>    <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }
    }
    else if(doublemode==3){
      if(simulate2d){ const bool sim2d=true;
        if(tkernel==KERNEL_Wendland)KerInteractionInOutExtrap_Double<sim2d,KERNEL_Wendland> <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionInOutExtrap_Double<sim2d,KERNEL_Cubic>    <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }else{          const bool sim2d=false;
        if(tkernel==KERNEL_Wendland)KerInteractionInOutExtrap_Double<sim2d,KERNEL_Wendland> <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionInOutExtrap_Double<sim2d,KERNEL_Cubic>    <<<sgrid,bsize>>> (inoutcount,inoutpart,cfgzone,computerhopmask,computevelmask,planes,width,dirdata,determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }
    }
  }
}


//##############################################################################
//# Kernels to extrapolate rhop on boundary particles (JSphBoundCorr).
//# Kernels para extrapolar rhop en las particulas de contorno (JSphBoundCorr).
//##############################################################################
//------------------------------------------------------------------------------
/// Perform interaction between ghost node of selected boundary and fluid.
//------------------------------------------------------------------------------
template<bool sim2d,TpKernel tker> __global__ void KerInteractionBoundCorr_Double
  (unsigned npb,typecode boundcode,float4 plane,float3 direction,float determlimit
  ,int hdiv,int4 nc,unsigned cellfluid,const int2 *begincell,int3 cellzero
  ,const double2 *posxy,const double *posz,const typecode *code,const unsigned *idp
  ,float4 *velrhop)
{
  const unsigned p1=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p1<npb && CODE_GetTypeAndValue(code[p1])==boundcode){
    float rhopfinal=FLT_MAX;
    //-Calculates ghost node position.
    double3 pos_p1=make_double3(posxy[p1].x,posxy[p1].y,posz[p1]);
    if(CODE_IsPeriodic(code[p1]))pos_p1=KerInteraction_PosNoPeriodic(pos_p1);
    const double displane=cumath::DistPlane(plane,pos_p1)*2;
    if(displane<=CTE.h*4.f){
      const double3 posp1=make_double3(pos_p1.x+displane*direction.x, pos_p1.y+displane*direction.y, pos_p1.z+displane*direction.z); //-Ghost node position.
      //-Initializes variables for calculation.
      double rhopp1=0;
      double3 gradrhopp1=make_double3(0,0,0);
      tmatrix3d a_corr2; if(sim2d) cumath::Tmatrix3dReset(a_corr2); //-Only for 2D.
      tmatrix4d a_corr3; if(!sim2d)cumath::Tmatrix4dReset(a_corr3); //-Only for 3D.

      //-Obtains interaction limits.
      int cxini,cxfin,yini,yfin,zini,zfin;
      cusph::KerGetInteractionCells(posp1.x,posp1.y,posp1.z,hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

      //-Interaction with fluids.
      for(int z=zini;z<zfin;z++){
        int zmod=(nc.w)*z+cellfluid; //-The sum showing where fluid cells start. | Le suma donde empiezan las celdas de fluido.
        for(int y=yini;y<yfin;y++){
          int ymod=zmod+nc.x*y;
          unsigned pini,pfin=0;
          for(int x=cxini;x<cxfin;x++){
            int2 cbeg=begincell[x+ymod];
            if(cbeg.y){
              if(!pfin)pini=cbeg.x;
              pfin=cbeg.y;
            }
          }
          if(pfin)for(unsigned p2=pini;p2<pfin;p2++){
            const double2 p2xy=posxy[p2];
            const double drx=double(posp1.x-p2xy.x);
            const double dry=double(posp1.y-p2xy.y);
            const double drz=double(posp1.z-posz[p2]);
            const double rr2=drx*drx+dry*dry+drz*drz;
            if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO && CODE_IsFluid(code[p2])){//-Only with fluid particles (including inout).
              //-Wendland or Cubic Spline kernel.
              float ffrx,ffry,ffrz,fwab;
              if(tker==KERNEL_Wendland)cusph::KerGetKernelWendland(float(rr2),float(drx),float(dry),float(drz),ffrx,ffry,ffrz,fwab);
              else if(tker==KERNEL_Cubic)cusph::KerGetKernelCubic(float(rr2),float(drx),float(dry),float(drz),ffrx,ffry,ffrz,fwab);
              const double frx=ffrx,fry=ffry,frz=ffrz,wab=fwab;

              //===== Get mass and volume of particle p2 =====
              const double massp2=CTE.massf;
              const double volp2=massp2/double(velrhop[p2].w);

              //===== Density and its gradient =====
              rhopp1+=massp2*wab;
              gradrhopp1.x+=massp2*frx;
              gradrhopp1.y+=massp2*fry;
              gradrhopp1.z+=massp2*frz;

              //===== Kernel values multiplied by volume =====
              const double vwab=wab*volp2;
              const double vfrx=frx*volp2;
              const double vfry=fry*volp2;
              const double vfrz=frz*volp2;

              //===== Matrix A for correction =====
              if(sim2d){
                a_corr2.a11+=vwab;  a_corr2.a12+=drx*vwab;  a_corr2.a13+=drz*vwab;
                a_corr2.a21+=vfrx;  a_corr2.a22+=drx*vfrx;  a_corr2.a23+=drz*vfrx;
                a_corr2.a31+=vfrz;  a_corr2.a32+=drx*vfrz;  a_corr2.a33+=drz*vfrz;
              }
              else{
                a_corr3.a11+=vwab;  a_corr3.a12+=drx*vwab;  a_corr3.a13+=dry*vwab;  a_corr3.a14+=drz*vwab;
                a_corr3.a21+=vfrx;  a_corr3.a22+=drx*vfrx;  a_corr3.a23+=dry*vfrx;  a_corr3.a24+=drz*vfrx;
                a_corr3.a31+=vfry;  a_corr3.a32+=drx*vfry;  a_corr3.a33+=dry*vfry;  a_corr3.a34+=drz*vfry;
                a_corr3.a41+=vfrz;  a_corr3.a42+=drx*vfrz;  a_corr3.a43+=dry*vfrz;  a_corr3.a44+=drz*vfrz;
              }
            }
          }
        }
      }

      //-Store the results.
      //--------------------
      const double3 dpos=make_double3(pos_p1.x-posp1.x, pos_p1.y-posp1.y, pos_p1.z-posp1.z); //-Boundary particle position - ghost node position.
      if(sim2d){
        const double determ=cumath::Determinant3x3(a_corr2);
        if(determ>=determlimit){//-Use 1e-3f (first_order) or 1e+3f (zeroth_order).
          const tmatrix3d invacorr2=cumath::InverseMatrix3x3(a_corr2,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          const double rhoghost=rhopp1*invacorr2.a11 + gradrhopp1.x*invacorr2.a12 + gradrhopp1.z*invacorr2.a13;
          const double grx=-(rhopp1*invacorr2.a21 + gradrhopp1.x*invacorr2.a22 + gradrhopp1.z*invacorr2.a23);
          const double grz=-(rhopp1*invacorr2.a31 + gradrhopp1.x*invacorr2.a32 + gradrhopp1.z*invacorr2.a33);
          rhopfinal=float(rhoghost + grx*dpos.x + grz*dpos.z);
        }
        else if(a_corr2.a11>0){//-Determinant is small but a11 is nonzero, 0th order ANGELO.
          rhopfinal=float(rhopp1/a_corr2.a11);
        }
      }
      else{
        const double determ=cumath::Determinant4x4(a_corr3);
        if(determ>=determlimit){
          const tmatrix4d invacorr3=cumath::InverseMatrix4x4(a_corr3,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          const double rhoghost=rhopp1*invacorr3.a11 + gradrhopp1.x*invacorr3.a12 + gradrhopp1.y*invacorr3.a13 + gradrhopp1.z*invacorr3.a14;
          const double grx=   -(rhopp1*invacorr3.a21 + gradrhopp1.x*invacorr3.a22 + gradrhopp1.y*invacorr3.a23 + gradrhopp1.z*invacorr3.a24);
          const double gry=   -(rhopp1*invacorr3.a31 + gradrhopp1.x*invacorr3.a32 + gradrhopp1.y*invacorr3.a33 + gradrhopp1.z*invacorr3.a34);
          const double grz=   -(rhopp1*invacorr3.a41 + gradrhopp1.x*invacorr3.a42 + gradrhopp1.y*invacorr3.a43 + gradrhopp1.z*invacorr3.a44);
          rhopfinal=float(rhoghost + grx*dpos.x + gry*dpos.y + grz*dpos.z);
        }
        else if(a_corr3.a11>0){//-Determinant is small but a11 is nonzero, 0th order ANGELO.
          rhopfinal=float(rhopp1/a_corr3.a11);
        }
      }
    }
    velrhop[p1].w=(rhopfinal!=FLT_MAX? rhopfinal: CTE.rhopzero);
  }
}

//------------------------------------------------------------------------------
/// Perform interaction between ghost node of selected boundary and fluid.
//------------------------------------------------------------------------------
template<bool sim2d,TpKernel tker> __global__ void KerInteractionBoundCorr_Single
  (unsigned npb,typecode boundcode,float4 plane,float3 direction,float determlimit
  ,int hdiv,int4 nc,unsigned cellfluid,const int2 *begincell,int3 cellzero
  ,const double2 *posxy,const double *posz,const typecode *code,const unsigned *idp
  ,float4 *velrhop)
{
  const unsigned p1=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p1<npb && CODE_GetTypeAndValue(code[p1])==boundcode){
    float rhopfinal=FLT_MAX;
    //-Calculates ghost node position.
    double3 pos_p1=make_double3(posxy[p1].x,posxy[p1].y,posz[p1]);
    if(CODE_IsPeriodic(code[p1]))pos_p1=KerInteraction_PosNoPeriodic(pos_p1);
    const double displane=cumath::DistPlane(plane,pos_p1)*2;
    if(displane<=CTE.h*4.f){
      const double3 posp1=make_double3(pos_p1.x+displane*direction.x, pos_p1.y+displane*direction.y, pos_p1.z+displane*direction.z); //-Ghost node position.
      //-Initializes variables for calculation.
      float rhopp1=0;
      float3 gradrhopp1=make_float3(0,0,0);
      tmatrix3d a_corr2; if(sim2d) cumath::Tmatrix3dReset(a_corr2); //-Only for 2D.
      tmatrix4d a_corr3; if(!sim2d)cumath::Tmatrix4dReset(a_corr3); //-Only for 3D.

      //-Obtains interaction limits.
      int cxini,cxfin,yini,yfin,zini,zfin;
      cusph::KerGetInteractionCells(posp1.x,posp1.y,posp1.z,hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

      //-Interaction with fluids.
      for(int z=zini;z<zfin;z++){
        int zmod=(nc.w)*z+cellfluid; //-The sum showing where fluid cells start. | Le suma donde empiezan las celdas de fluido.
        for(int y=yini;y<yfin;y++){
          int ymod=zmod+nc.x*y;
          unsigned pini,pfin=0;
          for(int x=cxini;x<cxfin;x++){
            int2 cbeg=begincell[x+ymod];
            if(cbeg.y){
              if(!pfin)pini=cbeg.x;
              pfin=cbeg.y;
            }
          }
          if(pfin)for(unsigned p2=pini;p2<pfin;p2++){
            const double2 p2xy=posxy[p2];
            const float drx=float(posp1.x-p2xy.x);
            const float dry=float(posp1.y-p2xy.y);
            const float drz=float(posp1.z-posz[p2]);
            const float rr2=drx*drx+dry*dry+drz*drz;
            if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO && CODE_IsFluid(code[p2])){//-Only with fluid particles (including inout).
              //-Wendland or Cubic Spline kernel.
              float frx,fry,frz,wab;
              if(tker==KERNEL_Wendland)cusph::KerGetKernelWendland(rr2,drx,dry,drz,frx,fry,frz,wab);
              else if(tker==KERNEL_Cubic)cusph::KerGetKernelCubic(rr2,drx,dry,drz,frx,fry,frz,wab);

              //===== Get mass and volume of particle p2 =====
              float massp2=CTE.massf;
              const float volp2=massp2/velrhop[p2].w;

              //===== Density and its gradient =====
              rhopp1+=massp2*wab;
              gradrhopp1.x+=massp2*frx;
              gradrhopp1.y+=massp2*fry;
              gradrhopp1.z+=massp2*frz;

              //===== Kernel values multiplied by volume =====
              const float vwab=wab*volp2;
              const float vfrx=frx*volp2;
              const float vfry=fry*volp2;
              const float vfrz=frz*volp2;

              //===== Matrix A for correction =====
              if(sim2d){
                a_corr2.a11+=vwab;  a_corr2.a12+=drx*vwab;  a_corr2.a13+=drz*vwab;
                a_corr2.a21+=vfrx;  a_corr2.a22+=drx*vfrx;  a_corr2.a23+=drz*vfrx;
                a_corr2.a31+=vfrz;  a_corr2.a32+=drx*vfrz;  a_corr2.a33+=drz*vfrz;
              }
              else{
                a_corr3.a11+=vwab;  a_corr3.a12+=drx*vwab;  a_corr3.a13+=dry*vwab;  a_corr3.a14+=drz*vwab;
                a_corr3.a21+=vfrx;  a_corr3.a22+=drx*vfrx;  a_corr3.a23+=dry*vfrx;  a_corr3.a24+=drz*vfrx;
                a_corr3.a31+=vfry;  a_corr3.a32+=drx*vfry;  a_corr3.a33+=dry*vfry;  a_corr3.a34+=drz*vfry;
                a_corr3.a41+=vfrz;  a_corr3.a42+=drx*vfrz;  a_corr3.a43+=dry*vfrz;  a_corr3.a44+=drz*vfrz;
              }
            }
          }
        }
      }

      //-Store the results.
      //--------------------
      const float3 dpos=make_float3(float(pos_p1.x-posp1.x),float(pos_p1.y-posp1.y),float(pos_p1.z-posp1.z)); //-Boundary particle position - ghost node position.
      if(sim2d){
        const double determ=cumath::Determinant3x3(a_corr2);
        if(determ>=determlimit){//-Use 1e-3f (first_order) or 1e+3f (zeroth_order).
          const tmatrix3d invacorr2=cumath::InverseMatrix3x3(a_corr2,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          const float rhoghost=float(invacorr2.a11*rhopp1 + invacorr2.a12*gradrhopp1.x + invacorr2.a13*gradrhopp1.z);
          const float grx=    -float(invacorr2.a21*rhopp1 + invacorr2.a22*gradrhopp1.x + invacorr2.a23*gradrhopp1.z);
          const float grz=    -float(invacorr2.a31*rhopp1 + invacorr2.a32*gradrhopp1.x + invacorr2.a33*gradrhopp1.z);
          rhopfinal=(rhoghost + grx*dpos.x + grz*dpos.z);
        }
        else if(a_corr2.a11>0){//-Determinant is small but a11 is nonzero, 0th order ANGELO.
          rhopfinal=float(rhopp1/a_corr2.a11);
        }
      }
      else{
        const double determ=cumath::Determinant4x4(a_corr3);
        if(determ>=determlimit){
          const tmatrix4d invacorr3=cumath::InverseMatrix4x4(a_corr3,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          const float rhoghost=float(invacorr3.a11*rhopp1 + invacorr3.a12*gradrhopp1.x + invacorr3.a13*gradrhopp1.y + invacorr3.a14*gradrhopp1.z);
          const float grx=    -float(invacorr3.a21*rhopp1 + invacorr3.a22*gradrhopp1.x + invacorr3.a23*gradrhopp1.y + invacorr3.a24*gradrhopp1.z);
          const float gry=    -float(invacorr3.a31*rhopp1 + invacorr3.a32*gradrhopp1.x + invacorr3.a33*gradrhopp1.y + invacorr3.a34*gradrhopp1.z);
          const float grz=    -float(invacorr3.a41*rhopp1 + invacorr3.a42*gradrhopp1.x + invacorr3.a43*gradrhopp1.y + invacorr3.a44*gradrhopp1.z);
          rhopfinal=(rhoghost + grx*dpos.x + gry*dpos.y + grz*dpos.z);
        }
        else if(a_corr3.a11>0){//-Determinant is small but a11 is nonzero, 0th order ANGELO.
          rhopfinal=float(rhopp1/a_corr3.a11);
        }
      }
    }
    velrhop[p1].w=(rhopfinal!=FLT_MAX? rhopfinal: CTE.rhopzero);
  }
}


//------------------------------------------------------------------------------
/// Perform interaction between ghost node of selected boundary and fluid.
//------------------------------------------------------------------------------
template<bool sim2d,TpKernel tker> __global__ void KerInteractionBoundCorr_FastSingle
  (unsigned npb,typecode boundcode,float4 plane,float3 direction,float determlimit
  ,int hdiv,int4 nc,unsigned cellfluid,const int2 *begincell,int3 cellzero
  ,const double2 *posxy,const double *posz,const typecode *code,const unsigned *idp
  ,float4 *velrhop)
{
  const unsigned p1=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p1<npb && CODE_GetTypeAndValue(code[p1])==boundcode){
    float rhopfinal=FLT_MAX;
    //-Calculates ghost node position.
    double3 pos_p1=make_double3(posxy[p1].x,posxy[p1].y,posz[p1]);
    if(CODE_IsPeriodic(code[p1]))pos_p1=KerInteraction_PosNoPeriodic(pos_p1);
    const double displane=cumath::DistPlane(plane,pos_p1)*2;
    if(displane<=CTE.h*4.f){
      const double3 posp1=make_double3(pos_p1.x+displane*direction.x, pos_p1.y+displane*direction.y, pos_p1.z+displane*direction.z); //-Ghost node position.
      //-Initializes variables for calculation.
      float rhopp1=0;
      float3 gradrhopp1=make_float3(0,0,0);
      tmatrix3f a_corr2; if(sim2d) cumath::Tmatrix3fReset(a_corr2); //-Only for 2D.
      tmatrix4f a_corr3; if(!sim2d)cumath::Tmatrix4fReset(a_corr3); //-Only for 3D.

      //-Obtains interaction limits.
      int cxini,cxfin,yini,yfin,zini,zfin;
      cusph::KerGetInteractionCells(posp1.x,posp1.y,posp1.z,hdiv,nc,cellzero,cxini,cxfin,yini,yfin,zini,zfin);

      //-Interaction with fluids.
      for(int z=zini;z<zfin;z++){
        int zmod=(nc.w)*z+cellfluid; //-The sum showing where fluid cells start. | Le suma donde empiezan las celdas de fluido.
        for(int y=yini;y<yfin;y++){
          int ymod=zmod+nc.x*y;
          unsigned pini,pfin=0;
          for(int x=cxini;x<cxfin;x++){
            int2 cbeg=begincell[x+ymod];
            if(cbeg.y){
              if(!pfin)pini=cbeg.x;
              pfin=cbeg.y;
            }
          }
          if(pfin)for(unsigned p2=pini;p2<pfin;p2++){
            const double2 p2xy=posxy[p2];
            const float drx=float(posp1.x-p2xy.x);
            const float dry=float(posp1.y-p2xy.y);
            const float drz=float(posp1.z-posz[p2]);
            const float rr2=drx*drx+dry*dry+drz*drz;
            if(rr2<=CTE.fourh2 && rr2>=ALMOSTZERO && CODE_IsFluid(code[p2])){//-Only with fluid particles (including inout).
              //-Wendland or Cubic Spline kernel.
              float frx,fry,frz,wab;
              if(tker==KERNEL_Wendland)cusph::KerGetKernelWendland(rr2,drx,dry,drz,frx,fry,frz,wab);
              else if(tker==KERNEL_Cubic)cusph::KerGetKernelCubic(rr2,drx,dry,drz,frx,fry,frz,wab);

              //===== Get mass and volume of particle p2 =====
              float massp2=CTE.massf;
              const float volp2=massp2/velrhop[p2].w;

              //===== Density and its gradient =====
              rhopp1+=massp2*wab;
              gradrhopp1.x+=massp2*frx;
              gradrhopp1.y+=massp2*fry;
              gradrhopp1.z+=massp2*frz;

              //===== Kernel values multiplied by volume =====
              const float vwab=wab*volp2;
              const float vfrx=frx*volp2;
              const float vfry=fry*volp2;
              const float vfrz=frz*volp2;

              //===== Matrix A for correction =====
              if(sim2d){
                a_corr2.a11+=vwab;  a_corr2.a12+=drx*vwab;  a_corr2.a13+=drz*vwab;
                a_corr2.a21+=vfrx;  a_corr2.a22+=drx*vfrx;  a_corr2.a23+=drz*vfrx;
                a_corr2.a31+=vfrz;  a_corr2.a32+=drx*vfrz;  a_corr2.a33+=drz*vfrz;
              }
              else{
                a_corr3.a11+=vwab;  a_corr3.a12+=drx*vwab;  a_corr3.a13+=dry*vwab;  a_corr3.a14+=drz*vwab;
                a_corr3.a21+=vfrx;  a_corr3.a22+=drx*vfrx;  a_corr3.a23+=dry*vfrx;  a_corr3.a24+=drz*vfrx;
                a_corr3.a31+=vfry;  a_corr3.a32+=drx*vfry;  a_corr3.a33+=dry*vfry;  a_corr3.a34+=drz*vfry;
                a_corr3.a41+=vfrz;  a_corr3.a42+=drx*vfrz;  a_corr3.a43+=dry*vfrz;  a_corr3.a44+=drz*vfrz;
              }
            }
          }
        }
      }

      //-Store the results.
      //--------------------
      const float3 dpos=make_float3(float(pos_p1.x-posp1.x),float(pos_p1.y-posp1.y),float(pos_p1.z-posp1.z)); //-Boundary particle position - ghost node position.
      if(sim2d){
//if(-a_corr2.a22-a_corr2.a33>0.9){ //-Suggested by Renato...
        const double determ=cumath::Determinant3x3dbl(a_corr2);
        if(determ>=determlimit){//-Use 1e-3f (first_order) or 1e+3f (zeroth_order).
          const tmatrix3f invacorr2=cumath::InverseMatrix3x3dbl(a_corr2,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          const float rhoghost=float(invacorr2.a11*rhopp1 + invacorr2.a12*gradrhopp1.x + invacorr2.a13*gradrhopp1.z);
          const float grx=    -float(invacorr2.a21*rhopp1 + invacorr2.a22*gradrhopp1.x + invacorr2.a23*gradrhopp1.z);
          const float grz=    -float(invacorr2.a31*rhopp1 + invacorr2.a32*gradrhopp1.x + invacorr2.a33*gradrhopp1.z);
          rhopfinal=(rhoghost + grx*dpos.x + grz*dpos.z);
        }
        else if(a_corr2.a11>0){//-Determinant is small but a11 is nonzero, 0th order ANGELO.
          rhopfinal=float(rhopp1/a_corr2.a11);
        }
//}
      }
      else{
        const double determ=cumath::Determinant4x4dbl(a_corr3);
        if(determ>=determlimit){
          const tmatrix4f invacorr3=cumath::InverseMatrix4x4dbl(a_corr3,determ);
          //-GHOST NODE DENSITY IS MIRRORED BACK TO THE INFLOW OR OUTFLOW PARTICLES.
          const float rhoghost=float(invacorr3.a11*rhopp1 + invacorr3.a12*gradrhopp1.x + invacorr3.a13*gradrhopp1.y + invacorr3.a14*gradrhopp1.z);
          const float grx=    -float(invacorr3.a21*rhopp1 + invacorr3.a22*gradrhopp1.x + invacorr3.a23*gradrhopp1.y + invacorr3.a24*gradrhopp1.z);
          const float gry=    -float(invacorr3.a31*rhopp1 + invacorr3.a32*gradrhopp1.x + invacorr3.a33*gradrhopp1.y + invacorr3.a34*gradrhopp1.z);
          const float grz=    -float(invacorr3.a41*rhopp1 + invacorr3.a42*gradrhopp1.x + invacorr3.a43*gradrhopp1.y + invacorr3.a44*gradrhopp1.z);
          rhopfinal=(rhoghost + grx*dpos.x + gry*dpos.y + grz*dpos.z);
        }
        else if(a_corr3.a11>0){//-Determinant is small but a11 is nonzero, 0th order ANGELO.
          rhopfinal=float(rhopp1/a_corr3.a11);
        }
      }
    }
    velrhop[p1].w=(rhopfinal!=FLT_MAX? rhopfinal: CTE.rhopzero);
  }
}

//==============================================================================
/// Perform interaction between ghost node of selected boundary and fluid.
//==============================================================================
void Interaction_BoundCorr(byte doublemode,bool simulate2d,TpKernel tkernel,TpCellMode cellmode
  ,unsigned npbok,typecode boundcode,tfloat4 plane,tfloat3 direction,float determlimit
  ,tuint3 ncells,const int2 *begincell,tuint3 cellmin
  ,const double2 *posxy,const double *posz,const typecode *code,const unsigned *idp
  ,float4 *velrhop)
{
  //-Executes particle interactions.
  const int hdiv=(cellmode==CELLMODE_H? 2: 1);
  const int4 nc=make_int4(int(ncells.x),int(ncells.y),int(ncells.z),int(ncells.x*ncells.y));
  const unsigned cellfluid=nc.w*nc.z+1;
  const int3 cellzero=make_int3(cellmin.x,cellmin.y,cellmin.z);
  //-Interaction GhostBoundaryNodes-Fluid.
  if(npbok){
    const unsigned bsbound=128;
    dim3 sgridb=cusph::GetGridSize(npbok,bsbound);
    if(doublemode==1){
      if(simulate2d){ const bool sim2d=true;
        if(tkernel==KERNEL_Wendland)KerInteractionBoundCorr_FastSingle<sim2d,KERNEL_Wendland> <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionBoundCorr_FastSingle<sim2d,KERNEL_Cubic>    <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }else{          const bool sim2d=false;
        if(tkernel==KERNEL_Wendland)KerInteractionBoundCorr_FastSingle<sim2d,KERNEL_Wendland> <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionBoundCorr_FastSingle<sim2d,KERNEL_Cubic>    <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }
    }
    else if(doublemode==2){
      if(simulate2d){ const bool sim2d=true;
        if(tkernel==KERNEL_Wendland)KerInteractionBoundCorr_Single<sim2d,KERNEL_Wendland> <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionBoundCorr_Single<sim2d,KERNEL_Cubic>    <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }else{          const bool sim2d=false;
        if(tkernel==KERNEL_Wendland)KerInteractionBoundCorr_Single<sim2d,KERNEL_Wendland> <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionBoundCorr_Single<sim2d,KERNEL_Cubic>    <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }
    }
    else if(doublemode==3){
      if(simulate2d){ const bool sim2d=true;
        if(tkernel==KERNEL_Wendland)KerInteractionBoundCorr_Double<sim2d,KERNEL_Wendland> <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionBoundCorr_Double<sim2d,KERNEL_Cubic>    <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }else{          const bool sim2d=false;
        if(tkernel==KERNEL_Wendland)KerInteractionBoundCorr_Double<sim2d,KERNEL_Wendland> <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
        if(tkernel==KERNEL_Cubic)   KerInteractionBoundCorr_Double<sim2d,KERNEL_Cubic>    <<<sgridb,bsbound>>> (npbok,boundcode,Float4(plane),Float3(direction),determlimit,hdiv,nc,cellfluid,begincell,cellzero,posxy,posz,code,idp,velrhop);
      }
    }
  }
}


//##############################################################################
//# Kernels to interpolate velocity (JSphInOutGridDataTime).
//# Kernels para interpolar valores de velocidad (JSphInOutGridDataTime).
//##############################################################################
//------------------------------------------------------------------------------
/// Interpolate data between time0 and time1.
//------------------------------------------------------------------------------
__global__ void KerInOutInterpolateTime(unsigned npt,double fxtime
  ,const float *vel0,const float *vel1,float *vel)
{
  const unsigned p=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(p<npt){
    const float v0=vel0[p];
    vel[p]=float(fxtime*(vel1[p]-v0)+v0);
  }
}

//==============================================================================
/// Interpolate data between time0 and time1.
//==============================================================================
void InOutInterpolateTime(unsigned npt,double time,double t0,double t1
  ,const float *velx0,const float *velx1,float *velx
  ,const float *velz0,const float *velz1,float *velz)
{
  if(npt){
    const double fxtime=((time-t0)/(t1-t0));
    dim3 sgrid=cusph::GetGridSize(npt,SPHBSIZE);
    KerInOutInterpolateTime <<<sgrid,SPHBSIZE>>> (npt,fxtime,velx0,velx1,velx);
    if(velz0)KerInOutInterpolateTime <<<sgrid,SPHBSIZE>>> (npt,fxtime,velz0,velz1,velz);
  }
}

//------------------------------------------------------------------------------
/// Interpolate velocity in time and Z-position of selected partiles in a list.
//------------------------------------------------------------------------------
__global__ void KerInOutInterpolateZVel(unsigned izone,double posminz,double dpz,int nz1
  ,const float *velx,const float *velz
  ,unsigned np,const int *plist,const double *posz,const typecode *code,float4 *velrhop)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<np){
    const unsigned p=plist[cp];
    if(izone==CODE_GetIzoneFluidInout(code[p])){
      const double pz=posz[p]-posminz;
      int cz=int(pz/dpz);
      cz=max(cz,0);
      cz=min(cz,nz1);
      const double fz=(pz/dpz-cz);  //const double fz=(pz-Dpz*cz)/Dpz;
      //-Interpolation in Z.
      const unsigned cp=cz;
      const float v00=velx[cp];
      const float v01=(cz<nz1? velx[cp+1]: v00);
      const float v=float(fz*(v01-v00)+v00);
      velrhop[p]=make_float4(v,0,0,velrhop[p].w);
      if(velz!=NULL){
        const float v00=velz[cp];
        const float v01=(cz<nz1? velz[cp+1]:    v00);
        const float v=float(fz*(v01-v00)+v00);
        velrhop[p].z=v;
      }
    }
  }
}

//==============================================================================
/// Interpolate velocity in time and Z-position of selected partiles in a list.
//==============================================================================
void InOutInterpolateZVel(unsigned izone,double posminz,double dpz,int nz1
  ,const float *velx,const float *velz
  ,unsigned np,const int *plist,const double *posz,const typecode *code,float4 *velrhop)
{
  if(np){
    dim3 sgrid=cusph::GetGridSize(np,SPHBSIZE);
    KerInOutInterpolateZVel <<<sgrid,SPHBSIZE>>> (izone,posminz,dpz,nz1,velx,velz,np,plist,posz,code,velrhop);
  }
}

//------------------------------------------------------------------------------
/// Removes interpolated Z velocity of inlet/outlet particles.
//------------------------------------------------------------------------------
__global__ void KerInOutInterpolateResetZVel(unsigned izone,unsigned np,const int *plist
  ,const typecode *code,float4 *velrhop)
{
  const unsigned cp=blockIdx.y*gridDim.x*blockDim.x + blockIdx.x*blockDim.x + threadIdx.x; //-Number of particle.
  if(cp<np){
    const unsigned p=plist[cp];
    if(izone==CODE_GetIzoneFluidInout(code[p]))velrhop[p].z=0;
  }
}

//==============================================================================
/// Removes interpolated Z velocity of inlet/outlet particles.
//==============================================================================
void InOutInterpolateResetZVel(unsigned izone,unsigned np,const int *plist
  ,const typecode *code,float4 *velrhop)
{
  if(np){
    dim3 sgrid=cusph::GetGridSize(np,SPHBSIZE);
    KerInOutInterpolateResetZVel <<<sgrid,SPHBSIZE>>> (izone,np,plist,code,velrhop);
  }
}



}


